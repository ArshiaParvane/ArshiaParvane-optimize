#!/usr/bin/env bash
# net-optimize.sh
# نسخه ساده‌تر برای مشتری – خروجی خلاصه و قابل فهم

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="net-optimize.sh"
STATE_DIR="/var/lib/net-optimize"
LOGFILE="/var/log/net-optimize.log"
SYSCTL_FILE="/etc/sysctl.d/99-net-optimize.conf"
SYSTEMD_UNIT_TEMPLATE="/etc/systemd/system/net-optimize@.service"

# Defaults
ACTION="dryrun"
PROFILE="balanced"
IFACE=""
MTU=""
VERBOSE=false

# Helpers
log(){ $VERBOSE && echo "[INFO] $*" | tee -a "$LOGFILE" >&2; }
warn(){ echo "[WARN] $*" | tee -a "$LOGFILE" >&2; }
die(){ echo "[ERROR] $*" | tee -a "$LOGFILE" >&2; exit 1; }
cmd(){ log "+ $*"; if [[ "$ACTION" == "apply" ]]; then eval "$@"; fi }
need_root(){ [[ $(id -u) -eq 0 ]] || die "باید با روت اجرا شود"; }
have(){ command -v "$1" >/dev/null 2>&1; }

# Parse args
usage(){ cat <<EOF
$SCRIPT_NAME [--apply|--revert|--status|--install-service|--remove-service]
             [--profile latency|balanced|throughput] [--iface IFACE] [--mtu N]
             [--verbose]
EOF
}

parse_args(){
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status) ACTION="status" ;;
      --apply) ACTION="apply" ;;
      --revert) ACTION="revert" ;;
      --install-service) ACTION="install_service" ;;
      --remove-service) ACTION="remove_service" ;;
      --profile) PROFILE="${2:-}"; shift ;;
      --iface) IFACE="${2:-}"; shift ;;
      --mtu) MTU="${2:-}"; shift ;;
      --verbose) VERBOSE=true ;;
      -h|--help) usage; exit 0 ;;
      *) usage; exit 2 ;;
    esac
    shift
  done
}

# Detection
detect_iface(){
  [[ -n "$IFACE" ]] && { echo "$IFACE"; return; }
  if have ip; then
    ip -o route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1
  fi
}

kernel_supports(){
  local feat="$1"
  case "$feat" in
    bbr)
      sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr && return 0
      modprobe -n -v tcp_bbr >/dev/null 2>&1 && return 0
      return 1 ;;
    cake)
      modprobe -n -v sch_cake >/dev/null 2>&1 && return 0
      return 1 ;;
  esac
}

ensure_bbr(){
  kernel_supports bbr || return 0
  if [[ "$ACTION" == "apply" ]]; then
    modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null || true
  fi
}

ensure_cake(){
  kernel_supports cake || return 0
  if [[ "$ACTION" == "apply" ]]; then
    modprobe sch_cake 2>/dev/null || true
  fi
}

# Sysctl
backup_sysctls(){ mkdir -p "$STATE_DIR"; sysctl -a > "$STATE_DIR/backup-$(date +%s).conf" 2>/dev/null; }

make_sysctl_payload(){
  local qdisc="fq_codel"; kernel_supports cake && qdisc="cake"
  local cc="bbr"; kernel_supports bbr || cc="cubic"
  cat <<SY
net.core.default_qdisc = $qdisc
net.ipv4.tcp_congestion_control = $cc
net.ipv4.tcp_fastopen = 1
net.ipv4.tcp_mtu_probing = 1
SY
}

apply_sysctl(){
  local payload
  payload=$(make_sysctl_payload)
  backup_sysctls
  ensure_bbr
  ensure_cake
  if [[ "$ACTION" == "apply" ]]; then
    printf "%s
" "$payload" > "$SYSCTL_FILE"
    sysctl -p "$SYSCTL_FILE" >/dev/null
  fi
}

# NIC tuning
set_mtu(){
  local dev="$1"
  [[ -z "$MTU" ]] && return
  if ! [[ "$MTU" =~ ^[0-9]+$ ]]; then die "MTU نامعتبر: $MTU"; fi
  if (( MTU < 576 )); then warn "MTU خیلی کوچک است ($MTU)"; fi
  cmd ip link set dev "$dev" mtu "$MTU"
}

# Systemd service
install_service(){
  local dev="$1"
  # ensure fixed path for ExecStart
  local BIN="/usr/local/sbin/net-optimize.sh"
  if [[ "$0" != "$BIN" ]]; then
    cp -f "$0" "$BIN"
    chmod +x "$BIN"
  fi
  cat >"$SYSTEMD_UNIT_TEMPLATE" <<SERV
[Unit]
Description=Network optimize for %I
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$BIN --apply --profile $PROFILE --iface %I ${MTU:+--mtu $MTU}

[Install]
WantedBy=multi-user.target
SERV
  if [[ "$ACTION" == "apply" ]]; then
    systemctl daemon-reload
    systemctl enable --now net-optimize@${dev}.service
  fi
}

remove_service(){
  local dev="$1"
  systemctl disable --now net-optimize@${dev}.service 2>/dev/null || true
  rm -f "$SYSTEMD_UNIT_TEMPLATE"
  systemctl daemon-reload
}

# Main
main(){
  parse_args "$@"
  need_root
  IFACE=$(detect_iface)
  [[ -z "$IFACE" ]] && die "iface پیدا نشد"

  case "$ACTION" in
    dryrun)
      echo "[Dry-run] Would apply profile=$PROFILE mtu=${MTU:-keep} iface=$IFACE"
      ;;
    apply)
      echo "[1/3] sysctl tuning …"
      apply_sysctl
      echo "[2/3] set MTU …"
      set_mtu "$IFACE"
      echo "[3/3] install service …"
      install_service "$IFACE"
      echo "✅ Done."
      status_report "$IFACE"
      ;;
    status)
      status_report "$IFACE" ;;
    revert)
      rm -f "$SYSCTL_FILE"; sysctl --system >/dev/null
      systemctl disable --now net-optimize@${IFACE}.service 2>/dev/null || true
      echo "Reverted sysctl (and disabled service if present)."
      ;;
    install_service)
      install_service "$IFACE" ;;
    remove_service)
      remove_service "$IFACE" ;;
  esac
}

main "$@"

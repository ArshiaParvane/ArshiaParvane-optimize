#!/usr/bin/env bash
# net-optimize.sh — Zero-touch + concise UI + safe & reversible (FA)
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="net-optimize.sh"
STATE_DIR="/var/lib/net-optimize"
LOGFILE="/var/log/net-optimize.log"
SYSCTL_FILE="/etc/sysctl.d/99-net-optimize.conf"
SYSTEMD_UNIT_TEMPLATE="/etc/systemd/system/net-optimize@.service"

# حتماً اگر مسیر ریپو عوض شد این URL را بروز کن
RAW_URL="${RAW_URL:-https://raw.githubusercontent.com/ArshiaParvane/ArshiaParvane-optimize/main/optimize.sh}"

# ===== Defaults (override via ENV) =====
ACTION="${ACTION:-dryrun}"                 # dryrun|apply|revert|status|install_service|remove_service
PROFILE="${PROFILE:-balanced}"             # latency|balanced|throughput
IFACE="${IFACE:-}"                         # empty = auto-detect
MTU="${MTU:-1420}"                         # 1420 default; set MTU="" to keep current
VERBOSE="${VERBOSE:-false}"
TUNE_OFFLOADS="${TUNE_OFFLOADS:-true}"
TUNE_COALESCE="${TUNE_COALESCE:-true}"
PIN_IRQS="${PIN_IRQS:-false}"

# Auto-apply when run via pipe with no args: curl ... | sudo bash
if [[ $# -eq 0 ]] && [[ ! -t 0 ]]; then ACTION="apply"; fi

# ===== Helpers =====
log(){ $VERBOSE && echo "[INFO] $*" | tee -a "$LOGFILE" >&2; }
warn(){ $VERBOSE && echo "[WARN] $*" | tee -a "$LOGFILE" >&2; }
die(){ echo "[ERROR] $*" | tee -a "$LOGFILE" >&2; exit 1; }
cmd(){ $VERBOSE && echo "+ $*" | tee -a "$LOGFILE" >&2; if [[ "$ACTION" == "apply" ]]; then eval "$@"; fi }
have(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [[ $(id -u) -eq 0 ]] || die "باید با روت اجرا شود"; }
p(){ echo "$*"; }

usage(){ cat <<EOF
$SCRIPT_NAME [--apply|--revert|--status|--install-service|--remove-service]
             [--profile latency|balanced|throughput] [--iface IFACE] [--mtu N]
             [--no-offloads] [--no-coalescing] [--pin-irqs] [--verbose]
ENV: ACTION PROFILE IFACE MTU VERBOSE TUNE_OFFLOADS TUNE_COALESCE PIN_IRQS RAW_URL
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
      --no-offloads) TUNE_OFFLOADS=false ;;
      --no-coalescing) TUNE_COALESCE=false ;;
      --pin-irqs) PIN_IRQS=true ;;
      --verbose) VERBOSE=true ;;
      -h|--help) usage; exit 0 ;;
      *) usage; exit 2 ;;
    esac; shift
  done
}

detect_iface(){
  [[ -n "$IFACE" ]] && { echo "$IFACE"; return; }
  have ip && ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1
}

kernel_supports(){
  local feat="$1"
  case "$feat" in
    bbr)  sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr && return 0
          modprobe -n -v tcp_bbr >/dev/null 2>&1 && return 0; return 1 ;;
    cake) modprobe -n -v sch_cake >/dev/null 2>&1 && return 0; return 1 ;;
  esac
}

ensure_bbr(){
  kernel_supports bbr || return 0
  [[ "$ACTION" == "apply" ]] || return 0
  modprobe tcp_bbr 2>/dev/null || true
  echo "tcp_bbr" >/etc/modules-load.d/bbr.conf 2>/dev/null || true
}

ensure_cake(){
  kernel_supports cake || return 0
  [[ "$ACTION" == "apply" ]] || return 0
  modprobe sch_cake 2>/dev/null || true
}

backup_sysctls(){ mkdir -p "$STATE_DIR"; sysctl -a > "$STATE_DIR/backup-$(date +%s).conf" 2>/dev/null; }

make_sysctl_payload(){
  local qdisc="fq_codel"; kernel_supports cake && qdisc="cake"
  local cc="bbr"; kernel_supports bbr || cc="cubic"
  case "$PROFILE" in
    latency)
      cat <<SY
net.core.default_qdisc = $qdisc
net.ipv4.tcp_congestion_control = $cc
net.ipv4.tcp_fastopen = 1
net.ipv4.tcp_mtu_probing = 1
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 131072 33554432
SY
      ;;
    throughput)
      cat <<SY
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $cc
net.ipv4.tcp_fastopen = 1
net.ipv4.tcp_mtu_probing = 1
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 16384
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_rmem = 4096 262144 67108864
net.ipv4.tcp_wmem = 4096 262144 67108864
SY
      ;;
    balanced|*)
      cat <<SY
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = $cc
net.ipv4.tcp_fastopen = 1
net.ipv4.tcp_mtu_probing = 1
net.core.somaxconn = 2048
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 131072 33554432
SY
      ;;
  esac
}

apply_sysctl(){
  local payload; payload=$(make_sysctl_payload)
  backup_sysctls
  ensure_bbr; ensure_cake
  if [[ "$ACTION" == "apply" ]]; then
    printf "%s\n" "$payload" > "$SYSCTL_FILE"
    sysctl -p "$SYSCTL_FILE" >/dev/null
  fi
}

set_mtu(){
  local dev="$1"
  [[ -z "${MTU:-}" ]] && return
  if ! [[ "$MTU" =~ ^[0-9]+$ ]]; then die "MTU نامعتبر: $MTU"; fi
  (( MTU < 576 )) && warn "MTU خیلی کوچک است ($MTU)"
  cmd ip link set dev "$dev" mtu "$MTU"
}

disable_offloads(){
  $TUNE_OFFLOADS || return 0
  local dev="$1"; have ethtool || { warn "ethtool نیست؛ offloads رد شد"; return; }
  for f in gro gso tso lro; do
    if ethtool -k "$dev" 2>/dev/null | awk -v ff="$f" '$1==ff":"{print $2,$3}' | grep -vq '\[fixed\]'; then
      cmd ethtool -K "$dev" "$f" off || warn "خاموش کردن $f نشد"
    fi
  done
}

set_coalescing(){
  $TUNE_COALESCE || return 0
  local dev="$1"; have ethtool || { warn "ethtool نیست؛ coalescing رد شد"; return; }
  case "$PROFILE" in
    latency)    cmd ethtool -C "$dev" adaptive-rx off adaptive-tx off rx-usecs 3 tx-usecs 3 || true ;;
    throughput) cmd ethtool -C "$dev" adaptive-rx on  adaptive-tx on  || true ;;
    balanced|*) cmd ethtool -C "$dev" adaptive-rx on  adaptive-tx on  rx-usecs 20 tx-usecs 20 || true ;;
  esac
}

pin_irqs(){
  $PIN_IRQS || return 0
  local dev="$1" ncpu mask
  ncpu=$(getconf _NPROCESSORS_ONLN || echo 1)
  (( ncpu < 2 )) && { warn "CPU کافی برای pin IRQ نیست"; return; }
  mask="2"
  while read -r irq _; do
    [[ -n "$irq" ]] || continue
    if [[ "$ACTION" == "apply" ]]; then echo "$mask" > "/proc/irq/$irq/smp_affinity" || true; fi
  done < <(grep -E "\b$dev\b" /proc/interrupts | awk -F: '{gsub(/^[ \t]+/,"",$1); print $1,":"}')
}

ui_panel(){
  local dev="$1"
  local profile="$PROFILE"
  local qdisc cc mtu svc_active svc_enabled
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  mtu=$(ip -o link show "$dev" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}')

  local sysctl_updated="no"; [[ -f "$SYSCTL_FILE" ]] && sysctl_updated="yes"
  local bbr_loaded="no"; lsmod 2>/dev/null | grep -q '^tcp_bbr' && bbr_loaded="yes"
  svc_active=$(systemctl is-active "net-optimize@${dev}.service" 2>/dev/null || echo "inactive")
  svc_enabled=$(systemctl is-enabled "net-optimize@${dev}.service" 2>/dev/null || echo "disabled")

  local gro gso tso lro rxu txu
  if have ethtool; then
    gro=$(ethtool -k "$dev" 2>/dev/null | awk '/\bgro:/{print $2}')
    gso=$(ethtool -k "$dev" 2>/dev/null | awk '/\bgso:/{print $2}')
    tso=$(ethtool -k "$dev" 2>/dev/null | awk '/\btso:/{print $2}')
    lro=$(ethtool -k "$dev" 2>/dev/null | awk '/\blro:/{print $2}')
    rxu=$(ethtool -c "$dev" 2>/dev/null | awk '/^rx-usecs:/{print $2}')
    txu=$(ethtool -c "$dev" 2>/dev/null | awk '/^tx-usecs:/{print $2}')
  else
    gro=gso=tso=lro=rxu=txu="n/a"
  fi

  local W=66 SEP
  SEP=$(printf '%*s' "$W" '' | tr ' ' '─')
  echo "┌${SEP}┐"
  printf "│ %-*s │\n" "$W" "Net Optimize Summary"
  echo "├${SEP}┤"
  printf "│ %-*s │\n" "$W" "Interface: ${dev}   Profile: ${profile}"
  printf "│ %-*s │\n" "$W" "qdisc: ${qdisc}     CC: ${cc}"
  printf "│ %-*s │\n" "$W" "MTU: ${mtu:-?}    Service: ${svc_active}/${svc_enabled}"
  echo "├${SEP}┤"
  printf "│ %-*s │\n" "$W" "Applied sysctl: ${sysctl_updated}   BBR loaded: ${bbr_loaded}"
  printf "│ %-*s │\n" "$W" "Offloads (gro/gso/tso/lro): ${gro:-n/a}/${gso:-n/a}/${tso:-n/a}/${lro:-n/a}"
  printf "│ %-*s │\n" "$W" "Coalescing (rx-usecs/tx-usecs): ${rxu:-n/a}/${txu:-n/a}"
  echo "└${SEP}┘"
}

install_service(){
  local dev="$1"
  local BIN="/usr/local/sbin/net-optimize.sh"

  # اگر از pipe اجرا شده یا $0 فایل نیست → از GitHub بکش
  if [[ ! -f "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]:-}" == "bash" ]]; then
    if have curl; then
      curl -fsSLo "$BIN" "$RAW_URL"
    elif have wget; then
      wget -qO "$BIN" "$RAW_URL"
    else
      die "curl/wget موجود نیست؛ نمی‌توان اسکریپت را در $BIN ذخیره کرد"
    fi
  else
    cp -f "${BASH_SOURCE[0]}" "$BIN"
  fi
  chmod +x "$BIN"

  cat >"$SYSTEMD_UNIT_TEMPLATE" <<SERV
[Unit]
Description=Network optimize for %I
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$BIN --apply --profile $PROFILE --iface %I ${MTU:+--mtu $MTU} ${TUNE_OFFLOADS:+} ${TUNE_COALESCE:+} ${PIN_IRQS:+--pin-irqs}

[Install]
WantedBy=multi-user.target
SERV

  if [[ "$ACTION" == "apply" ]]; then
    systemctl daemon-reload
    systemctl enable --now "net-optimize@${dev}.service"
  fi
}

remove_service(){
  local dev="$1"
  systemctl disable --now "net-optimize@${dev}.service" 2>/dev/null || true
  rm -f "$SYSTEMD_UNIT_TEMPLATE"
  systemctl daemon-reload
}

main(){
  parse_args "$@"
  need_root
  IFACE="$(detect_iface)"; [[ -z "$IFACE" ]] && die "iface پیدا نشد"

  case "$ACTION" in
    dryrun)
      p "[Dry-run] Would apply profile=$PROFILE mtu=${MTU:-keep} iface=$IFACE"
      ui_panel "$IFACE"
      ;;
    apply)
      p "[1/4] sysctl tuning …"; apply_sysctl
      p "[2/4] set MTU …"; set_mtu "$IFACE"
      p "[3/4] NIC features …"; disable_offloads "$IFACE"; set_coalescing "$IFACE"; $PIN_IRQS && { p "[opt] pin IRQs"; pin_irqs "$IFACE"; }
      p "[4/4] install service …"; install_service "$IFACE"
      echo "✅ Done."; ui_panel "$IFACE"
      ;;
    status) ui_panel "$IFACE" ;;
    revert)
      rm -f "$SYSCTL_FILE"; sysctl --system >/dev/null
      systemctl disable --now "net-optimize@${IFACE}.service" 2>/dev/null || true
      echo "Reverted sysctl (and disabled service if present)."; ui_panel "$IFACE"
      ;;
    install_service) install_service "$IFACE" ;;
    remove_service)  remove_service "$IFACE" ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"

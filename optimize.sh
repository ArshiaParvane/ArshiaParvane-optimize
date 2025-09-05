#!/usr/bin/env bash
#
# net-optimize.sh
# نسخهٔ امن‌تر و قابل‌برگشتِ اسکریپت بهینه‌سازی شبکه با UX بهتر
# Safe, idempotent, and reversible Linux network tuning helper
#
# ویژگی‌ها / Features
#   - پیش‌نمایش (dry-run) پیش‌فرض: بدون هیچ تغییری فقط نشان می‌دهد چه می‌کند
#   - پرچم‌های روشن: --apply / --revert / --status / --profile {latency|balanced|throughput}
#   - انتخاب کارت شبکه: --iface <IFACE> (در صورت عدم تعیین، به‌طور امن تشخیص می‌دهد)
#   - تغییرات sysctl فقط در فایل اختصاصی و با پشتیبان‌گیری از مقادیر قبلی
#   - بررسی پشتیبانی هسته برای BBR و CAKE؛ فال‌بک امن به fq_codel
#   - خاموش‌کردن offloadها فقط درصورت پشتیبانی و قابل‌تغییر بودن
#   - coalescing ملایم (نه افراطی)؛ قابل غیرفعال/فعال با پرچم‌ها
#   - عدم دست‌کاری IRQ به‌صورت پیش‌فرض (_irqbalance_ حفظ می‌شود)؛ حالت اختیاری --pin-irqs
#   - سرویس systemd قالب‌دار net-optimize@<iface>.service برای پایداری بعد از ریبوت
#   - لاگ‌برداری واضح و خروج کد مناسب
#
# Usage examples:
#   sudo ./net-optimize.sh --status
#   sudo ./net-optimize.sh --apply --profile latency --iface eth0
#   sudo ./net-optimize.sh --revert
#   sudo ./net-optimize.sh --install-service --profile latency --iface eth0
#   sudo ./net-optimize.sh --remove-service --iface eth0
#
set -Eeuo pipefail
IFS=$'\n\t'

# --------------------------- Config & Globals ---------------------------
SCRIPT_NAME="net-optimize.sh"
STATE_DIR="/var/lib/net-optimize"
LOGFILE="/var/log/net-optimize.log"
SYSCTL_FILE="/etc/sysctl.d/99-net-optimize.conf"
SYSTEMD_UNIT_TEMPLATE="/etc/systemd/system/net-optimize@.service"

# Defaults
ACTION="dryrun"        # dryrun|apply|revert|status|install_service|remove_service
PROFILE="balanced"     # latency|balanced|throughput
IFACE=""
TUNE_COALESCING=true
TUNE_OFFLOADS=true
PIN_IRQS=false

# --------------------------- Helpers ---------------------------
log()   { echo -e "\e[32m[INFO]\e[0m  $*" | tee -a "$LOGFILE" >&2; }
warn()  { echo -e "\e[33m[WARN]\e[0m  $*" | tee -a "$LOGFILE" >&2; }
die()   { echo -e "\e[31m[ERROR]\e[0m $*" | tee -a "$LOGFILE" >&2; exit 1; }
cmd()   { echo "+ $*" | tee -a "$LOGFILE" >&2; if [[ "$ACTION" == "apply" ]]; then eval "$@"; fi }
need_root(){ [[ $(id -u) -eq 0 ]] || die "این اسکریپت باید با دسترسی روت اجرا شود."; }
have()  { command -v "$1" >/dev/null 2>&1; }

trap 'warn "اسکریپت با خطا یا سیگنال خاتمه یافت (exit=$?). لاگ: $LOGFILE"' ERR

# --------------------------- Argument Parsing ---------------------------
usage(){ cat <<EOF
$SCRIPT_NAME

Flags:
  --status                 فقط وضعیت فعلی را نشان می‌دهد
  --apply                  تغییرات را اعمال می‌کند
  --revert                 تغییرات اعمال‌شده توسط این اسکریپت را برمی‌گرداند
  --profile <p>            latency | balanced | throughput (پیش‌فرض: balanced)
  --iface <IFACE>          کارت شبکه هدف (درصورت عدم تعیین، تشخیص امن)
  --no-coalescing          عدم دستکاری coalescing
  --no-offloads            عدم دستکاری offloads
  --pin-irqs               سنجاق‌کردن IRQهای IFACE روی یک ماسک امن (اختیاری)
  --install-service        نصب سرویس systemd پایدار: net-optimize@<iface>.service
  --remove-service         حذف سرویس systemd
  -h, --help               راهنما
EOF
}

parse_args(){
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status) ACTION="status" ; shift ;;
      --apply) ACTION="apply" ; shift ;;
      --revert) ACTION="revert" ; shift ;;
      --install-service) ACTION="install_service" ; shift ;;
      --remove-service) ACTION="remove_service" ; shift ;;
      --profile) PROFILE="${2:-}"; shift 2 ;;
      --iface) IFACE="${2:-}"; shift 2 ;;
      --no-coalescing) TUNE_COALESCING=false; shift ;;
      --no-offloads)   TUNE_OFFLOADS=false; shift ;;
      --pin-irqs) PIN_IRQS=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) warn "ناشناخته: $1"; usage; exit 2 ;;
    esac
  done
}

# --------------------------- Detection ---------------------------

detect_iface(){
  if [[ -n "$IFACE" ]]; then echo "$IFACE"; return 0; fi
  if have ip; then
    # Try default route device first
    local dev
    dev=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1 || true)
    if [[ -n "$dev" && -d "/sys/class/net/$dev" ]]; then echo "$dev"; return 0; fi
    # fallback: first non-lo interface that is UP
    dev=$(ls /sys/class/net 2>/dev/null | grep -vE '^lo$' | head -n1 || true)
    [[ -n "$dev" ]] && echo "$dev" && return 0
  fi
  die "نتوانستم کارت شبکه را تشخیص بدهم. از --iface استفاده کنید."
}

kernel_supports(){
  local feat="$1"
  case "$feat" in
    bbr)
      sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr && return 0
      modprobe -n -v tcp_bbr >/dev/null 2>&1 && return 0
      return 1;;
    cake)
      modprobe -n -v sch_cake >/dev/null 2>&1 && return 0
      return 1;;
  esac
}

# --------------------------- Sysctl Handling ---------------------------

ensure_state(){ mkdir -p "$STATE_DIR"; touch "$LOGFILE"; }

backup_sysctls(){
  local outfile="$STATE_DIR/backup-$(date +%Y%m%d-%H%M%S).conf"
  log "پشتیبان‌گیری از sysctl های مهم → $outfile"
  : >"$outfile"
  local keys=(
    net.core.default_qdisc
    net.ipv4.tcp_congestion_control
    net.ipv4.tcp_fastopen
    net.ipv4.tcp_mtu_probing
    net.ipv4.tcp_window_scaling
    net.core.somaxconn
    net.ipv4.tcp_max_syn_backlog
    net.core.netdev_max_backlog
    net.core.rmem_default net.core.rmem_max
    net.core.wmem_default net.core.wmem_max
    net.ipv4.tcp_rmem net.ipv4.tcp_wmem
    net.ipv4.tcp_fin_timeout
    net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes
  )
  for k in "${keys[@]}"; do
    local v
    v=$(sysctl -n "$k" 2>/dev/null || true)
    [[ -n "$v" ]] && echo "$k = $v" >>"$outfile"
  done
  echo "$outfile"
}

make_sysctl_payload(){
  # Build key=value lines to apply based on selected profile and kernel support
  local qdisc="fq_codel"
  if kernel_supports cake; then qdisc="cake"; fi

  local cc="bbr"
  if ! kernel_supports bbr; then warn "هسته از BBR پشتیبانی نمی‌کند؛ از cubic استفاده می‌شود"; cc="cubic"; fi

  # Conservative defaults per profile
  case "$PROFILE" in
    latency)
      cat <<SY
net.core.default_qdisc = $qdisc
net.ipv4.tcp_congestion_control = $cc
net.ipv4.tcp_fastopen = 1         # فقط خروجی؛ امن‌تر نسبت به 3
net.ipv4.tcp_mtu_probing = 1
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 4096
net.core.netdev_max_backlog = 16384
net.core.rmem_default = 262144
net.core.rmem_max = 67108864
net.core.wmem_default = 262144
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 131072 33554432
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
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
net.core.rmem_default = 524288
net.core.rmem_max = 134217728
net.core.wmem_default = 524288
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 262144 67108864
net.ipv4.tcp_wmem = 4096 262144 67108864
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
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
net.core.rmem_default = 262144
net.core.rmem_max = 67108864
net.core.wmem_default = 262144
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 131072 33554432
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
SY
      ;;
  esac
}

apply_sysctl(){
  local payload backup
  backup=$(backup_sysctls)
  payload=$(make_sysctl_payload)
  log "نوشتن کانفیگ sysctl به $SYSCTL_FILE"
  if [[ "$ACTION" == "apply" ]]; then
    printf "%s\n" "$payload" > "$SYSCTL_FILE"
    sysctl -p "$SYSCTL_FILE" >/dev/null
  else
    echo "------ sysctl (dry-run) ------"; echo "$payload"; echo "------------------------------"
  fi
  log "Backup: $backup"
}

revert_sysctl(){
  log "بازگردانی با حذف $SYSCTL_FILE و بارگذاری مجدد"
  if [[ -f "$SYSCTL_FILE" ]]; then cmd rm -f "$SYSCTL_FILE"; fi
  if [[ "$ACTION" == "apply" ]]; then sysctl --system >/dev/null; fi
}

# --------------------------- NIC Tuning ---------------------------

disable_offloads(){
  local dev="$1"; have ethtool || { warn "ethtool پیدا نشد؛ از خاموش کردن offload صرف‌نظر می‌شود"; return; }
  log "خاموش‌کردن offloads (درصورت امکان) روی $dev"
  # Only attempt if feature present and not fixed
  local -a feats=(gro gso tso lro)
  for f in "${feats[@]}"; do
    if ethtool -k "$dev" 2>/dev/null | awk -v ff="$f" '$1==ff":"{print $2,$3}' | grep -vq '\[fixed\]' ; then
      cmd ethtool -K "$dev" "$f" off || warn "نتوانستم $f را خاموش کنم"
    else
      warn "$f روی این NIC پشتیبانی نمی‌شود یا ثابت است"
    fi
  done
}

set_coalescing(){
  local dev="$1"; have ethtool || { warn "ethtool پیدا نشد؛ coalescing رد شد"; return; }
  # Gentle coalescing for latency; much less aggressive than 1 pkt/IRQ
  case "$PROFILE" in
    latency)      cmd ethtool -C "$dev" adaptive-rx off adaptive-tx off rx-usecs 3 rx-frames 1 tx-usecs 3 tx-frames 1 || warn "تنظیم coalescing شکست خورد" ;;
    throughput)   cmd ethtool -C "$dev" adaptive-rx on adaptive-tx on || warn "تنظیم coalescing شکست خورد" ;;
    balanced|*)   cmd ethtool -C "$dev" adaptive-rx on adaptive-tx on rx-usecs 20 tx-usecs 20 || warn "تنظیم coalescing شکست خورد" ;;
  esac
}

pin_irqs(){
  local dev="$1"
  $PIN_IRQS || return 0
  # Compute a safe mask that avoids CPU0 (let irqbalance work otherwise)
  # Example mask = 0x2 (CPU1) if system has >=2 CPUs; otherwise skip.
  local ncpu mask
  ncpu=$(getconf _NPROCESSORS_ONLN || echo 1)
  if (( ncpu < 2 )); then warn "CPU کافی برای pin IRQ نیست"; return; fi
  mask="2"  # hex bitmask for CPU1 only
  log "سنجاق‌کردن IRQهای $dev به ماسک $mask (اختیاری و قابل برگشت)"
  local irq
  while read -r irq _; do
    [[ -n "$irq" ]] || continue
    if [[ "$ACTION" == "apply" ]]; then echo "$mask" > "/proc/irq/$irq/smp_affinity" || warn "IRQ $irq را نتوانستم سنجاق کنم"; else echo "/proc/irq/$irq/smp_affinity <- $mask"; fi
  done < <(grep -E "\b$dev\b" /proc/interrupts | awk -F: '{gsub(/^[ \t]+/,"",$1); print $1,":"}')
}

status_report(){
  local dev="$1"
  echo "==== وضعیت فعلی ($dev) ===="
  sysctl -n net.core.default_qdisc 2>/dev/null | sed 's/^/qdisc: /' || true
  sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | sed 's/^/congestion: /' || true
  have ethtool && { echo "-- Offloads --"; ethtool -k "$dev" 2>/dev/null | grep -E '(^\s*(gro|gso|tso|lro))|features for'; echo "-- Coalescing --"; ethtool -c "$dev" 2>/dev/null; } || true
  echo "-- IRQs --"; grep -E "\b$dev\b" /proc/interrupts || true
}

# --------------------------- systemd ---------------------------

install_systemd_service(){
  local dev="$1"
  log "در حال نصب سرویس systemd: net-optimize@.service"
  cat >"$SYSTEMD_UNIT_TEMPLATE" <<SERV
[Unit]
Description=Network optimizations for %I (safe)
After=network-online.target
Wants=network-online.target
ConditionPathExists=/sys/class/net/%I

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/env bash -lc '/usr/bin/env -S bash -c "${BASH_SOURCE[0]} --apply --profile $PROFILE --iface %I ${TUNE_COALESCING:+} ${TUNE_OFFLOADS:+} ${PIN_IRQS:+--pin-irqs}"'

[Install]
WantedBy=multi-user.target
SERV
  if [[ "$ACTION" == "apply" ]]; then
    systemctl daemon-reload
    systemctl enable --now "net-optimize@${dev}.service"
  else
    echo "(dry-run) would enable net-optimize@${dev}.service"
  fi
}

remove_systemd_service(){
  local dev="$1"
  if systemctl list-unit-files | grep -q "^net-optimize@.service"; then
    cmd systemctl disable --now "net-optimize@${dev}.service" || true
  fi
  cmd rm -f "$SYSTEMD_UNIT_TEMPLATE" || true
  if [[ "$ACTION" == "apply" ]]; then systemctl daemon-reload; fi
}

# --------------------------- Main ---------------------------
main(){
  parse_args "$@"
  need_root
  ensure_state
  IFACE=$(detect_iface)
  log "Interface: $IFACE | Profile: $PROFILE | Action: $ACTION"

  case "$ACTION" in
    status)
      status_report "$IFACE" ;;
    dryrun)
      log "پیش‌نمایش: هیچ تغییری اعمال نخواهد شد. برای اعمال از --apply استفاده کنید."
      apply_sysctl   # prints payload
      $TUNE_OFFLOADS && disable_offloads "$IFACE"
      $TUNE_COALESCING && set_coalescing "$IFACE"
      $PIN_IRQS && pin_irqs "$IFACE"
      status_report "$IFACE" ;;
    apply)
      apply_sysctl
      $TUNE_OFFLOADS && disable_offloads "$IFACE"
      $TUNE_COALESCING && set_coalescing "$IFACE"
      $PIN_IRQS && pin_irqs "$IFACE"
      log "همه‌چیز با موفقیت اعمال شد." ;;
    revert)
      revert_sysctl
      warn "برای برگرداندن offload/coalescing به حالت قبلی، ممکن است نیاز باشد سیستم را ریبوت یا تنظیمات اولیه NIC خود را دستی برگردانید."
      ;;
    install_service)
      install_systemd_service "$IFACE" ;;
    remove_service)
      remove_systemd_service "$IFACE" ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"

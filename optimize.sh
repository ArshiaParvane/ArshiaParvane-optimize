#!/bin/bash
#
# optimize.sh
# اسکریپت نهایی برای اعمال تنظیماتِ هم‌زمانِ throughput و low-latency روی یک سرور لینوکسی:
#
# • تنظیم sysctl (only net.core.default_qdisc + BBR + Fast Open + بافرها + TIME-WAIT + Keepalive)
# • بارگذاری ماژول tcp_bbr و ثبت آن در بوت
# • تنظیم MTU اینترفیس پیش‌فرض روی 1420 و افزودن route /24 خودکار
# • خاموش‌سازی NIC offloadها (GRO, GSO, TSO, LRO) برای کمترین تأخیر
# • کاهش interrupt coalescing (هر بسته فوراً interrupt تولید کند)
# • تخصیص IRQ affinity به یک هستهٔ CPU برای ثبات بیشتر
#
# نحوهٔ استفاده:
#   curl -fsSL https://raw.githubusercontent.com/ArshiaParvane/ArshiaParvane-optimize/main/optimize.sh | sudo bash
#
# توضیحات:
#   • اگر سرور از cake پشتیبانی نکند، خودکار fq_codel جایگزین می‌شود.
#   • برای بازگرداندن MTU و route، به‌صورت دستی MTU را به 1500 برگردانید و route /24 را حذف کنید.
#
set -o errexit
set -o nounset
set -o pipefail

LOGFILE="/var/log/optimize.log"

die() {
  echo -e "\e[31m[ERROR]\e[0m $1" | tee -a "$LOGFILE"
  exit 1
}

log() {
  echo -e "\e[32m[INFO]\e[0m $1" | tee -a "$LOGFILE"
}

# مطمئن شو که اسکریپت با کاربر root اجرا می‌شود
if [ "$(id -u)" -ne 0 ]; then
  die "این اسکریپت باید با دسترسی root اجرا شود."
fi

log "شروع اعمال تنظیمات شبکه برای low-latency و throughput..."

# -----------------------------------------------------------
# ۱. تنظیم sysctl برای net.core.default_qdisc و سایر پارامترها
# -----------------------------------------------------------
declare -A sysctl_opts=(
  # Queueing: ترجیح cake، در صورت عدم پشتیبانی fq_codel
  ["net.core.default_qdisc"]="cake"

  # Congestion Control
  ["net.ipv4.tcp_congestion_control"]="bbr"

  # TCP Fast Open
  ["net.ipv4.tcp_fastopen"]="3"

  # MTU Probing
  ["net.ipv4.tcp_mtu_probing"]="1"

  # Window Scaling
  ["net.ipv4.tcp_window_scaling"]="1"

  # Backlog / SYN Queue
  ["net.core.somaxconn"]="1024"
  ["net.ipv4.tcp_max_syn_backlog"]="2048"
  ["net.core.netdev_max_backlog"]="500000"

  # Buffer sizes
  ["net.core.rmem_default"]="262144"
  ["net.core.rmem_max"]="134217728"
  ["net.core.wmem_default"]="262144"
  ["net.core.wmem_max"]="134217728"
  ["net.ipv4.tcp_rmem"]="4096 87380 67108864"
  ["net.ipv4.tcp_wmem"]="4096 65536 67108864"

  # TIME-WAIT reuse
  ["net.ipv4.tcp_tw_reuse"]="1"
  # ["net.ipv4.tcp_tw_recycle"]="1"   # غیرفعال شده تا مشکلات NAT پیش نیاید

  # FIN_TIMEOUT و Keepalive
  ["net.ipv4.tcp_fin_timeout"]="15"
  ["net.ipv4.tcp_keepalive_time"]="300"
  ["net.ipv4.tcp_keepalive_intvl"]="30"
  ["net.ipv4.tcp_keepalive_probes"]="5"

  # TCP No Metrics Save
  ["net.ipv4.tcp_no_metrics_save"]="1"
)

log "اعمال تنظیمات sysctl..."
for key in "${!sysctl_opts[@]}"; do
  value="${sysctl_opts[$key]}"

  if sysctl -w "$key=$value" >/dev/null 2>&1; then
    # اگر هنوز در /etc/sysctl.conf ثبت نشده، اضافه‌اش کن
    grep -qxF "$key = $value" /etc/sysctl.conf \
      || echo "$key = $value" >> /etc/sysctl.conf
    log "ثبت و اعمال شد: $key = $value"
  else
    # فقط برای qdisc: اگر cake ست نشد، fq_codel را امتحان کن
    if [[ "$key" == "net.core.default_qdisc" ]]; then
      fallback="fq_codel"
      sysctl -w "$key=$fallback" >/dev/null 2>&1 || die "نمی‌توان $key را روی $fallback تنظیم کرد"
      grep -qxF "$key = $fallback" /etc/sysctl.conf \
        || echo "$key = $fallback" >> /etc/sysctl.conf
      log "برای $key، fallback روی $fallback تنظیم شد."
    else
      die "شکست در تنظیم sysctl: $key=$value"
    fi
  fi
done

sysctl -p >/dev/null 2>&1 || die "بارگذاری مجدد sysctl با خطا مواجه شد."
log "تمام sysctlها اعمال و ذخیره شدند."

# -----------------------------------------------------------
# ۲. بارگذاری ماژول tcp_bbr
# -----------------------------------------------------------
log "بارگذاری ماژول tcp_bbr..."
if ! lsmod | grep -q '^tcp_bbr'; then
  modprobe tcp_bbr || die "بارگذاری ماژول tcp_bbr شکست خورد."
  echo "tcp_bbr" >/etc/modules-load.d/bbr.conf
  log "tcp_bbr بارگذاری و ثبت شد."
else
  log "ماژول tcp_bbr از قبل بارگذاری شده بود."
fi

# -----------------------------------------------------------
# ۳. تعیین اینترفیس پیش‌فرض و CIDR /24 خودکار
# -----------------------------------------------------------
get_iface_and_cidr() {
  local IFACE
  IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}') \
    || die "ناتوان در یافتن اینترفیس پیش‌فرض."
  local IP_ADDR
  IP_ADDR=$(ip -4 addr show "$IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1) \
    || die "ناتوان در خواندن IP اینترفیس $IFACE."
  local BASE
  BASE=$(echo "$IP_ADDR" | cut -d. -f1-3)
  local CIDR="${BASE}.0/24"
  echo "$IFACE" "$CIDR"
}

read IFACE CIDR < <(get_iface_and_cidr)
log "اینترفیس پیش‌فرض: $IFACE   CIDR خودکار: $CIDR"

# -----------------------------------------------------------
# ۴. تنظیم MTU روی 1420 و افزودن route خودکار
# -----------------------------------------------------------
current_mtu=$(ip link show "$IFACE" | grep -oP 'mtu \K[0-9]+')
if [ "$current_mtu" != "1420" ]; then
  ip link set dev "$IFACE" mtu 1420 || die "تنظیم MTU روی 1420 برای $IFACE شکست خورد."
  log "MTU اینترفیس $IFACE روی 1420 تنظیم شد."
else
  log "MTU اینترفیس $IFACE از قبل 1420 بود."
fi

if ! ip route show | grep -qw "$CIDR"; then
  ip route add "$CIDR" dev "$IFACE" || die "افزودن route $CIDR روی $IFACE شکست خورد."
  log "روت $CIDR به اینترفیس $IFACE اضافه شد."
else
  log "روت $CIDR از قبل وجود داشت."
fi

# -----------------------------------------------------------
# ۵. خاموش‌سازی NIC offloadها (GRO, GSO, TSO, LRO)
# -----------------------------------------------------------
log "خاموش‌سازی NIC offloadها روی $IFACE..."
ethtool -K "$IFACE" gro off gso off tso off lro off \
  && log "offloadها خاموش شدند." \
  || log "هشدار: NIC offloadها پشتیبانی نمی‌شوند یا قبلاً خاموش بودند."

# -----------------------------------------------------------
# ۶. کاهش interrupt coalescing (هر بسته فوراً interrupt تولید کند)
# -----------------------------------------------------------
log "کاهش interrupt coalescing روی $IFACE..."
ethtool -C "$IFACE" rx-usecs 0 rx-frames 1 tx-usecs 0 tx-frames 1 \
  && log "coalescing برای هر بسته روی یک interrupt تنظیم شد." \
  || log "هشدار: coalescing پشتیبانی نشد یا تغییر یافت."

# -----------------------------------------------------------
# ۷. تخصیص IRQ affinity به یک هستهٔ CPU (هستهٔ #1)
# -----------------------------------------------------------
log "تنظیم IRQ affinity برای $IFACE فقط روی هستهٔ CPU#1..."
for irq in $(grep -R "$IFACE" /proc/interrupts | awk -F: '{print $1}'); do
  echo 2 > /proc/irq/"$irq"/smp_affinity \
    && log "IRQ $irq به هستهٔ 1 تخصیص یافت." \
    || log "هشدار: تخصیص IRQ $irq به هستهٔ 1 موفق نبود."
done

# -----------------------------------------------------------
# ۸. خلاصهٔ نهایی و توصیه‌ها
# -----------------------------------------------------------
log "تمام تنظیمات low-latency و throughput اعمال شدند."
log "برای بررسی وضعیت:"
log "  • کنترل هم‌پخشی TCP:    sysctl net.ipv4.tcp_congestion_control"
log "  • MTU:                  ip link show $IFACE"
log "  • Route /24:            ip route show | grep \"$CIDR\""
log "  • offload:             ethtool -k $IFACE | grep -E 'gso|gro|tso|lro'"
log "  • coalescing:          ethtool -c $IFACE"
log "  • IRQ affinity:        grep \"$IFACE\" /proc/interrupts"

echo -e "\n\e[34m>>> تنظیمات اعمال شد. اکنون با ping و iperf3 تست کنید.\e[0m\n"
exit 0

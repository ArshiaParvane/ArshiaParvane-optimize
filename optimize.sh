#!/bin/bash
#
# tune-net.sh
# اسکریپتی جامع برای اعمال بهترین تنظیمات شبکه در سرور لینوکسی:
#   • تنظیم sysctl (BBR، fq/fq_codel، backlog، buffer، TIME-WAIT، keepalive و …)
#   • فعال‌سازی ماژول tcp_bbr و ثبت در بوت
#   • تغییر MTU روی اینترفیس پیش‌فرض به 1420
#   • افزودن یک route /24 خودکار بر اساس IP جاری
#   • فعال‌سازی NIC offloadها (GSO, GRO, TSO, LRO)
#   • افزایش RX/TX ring buffer
#   • تنظیم interrupt coalescing (coalesce) برای کاهش بار CPU
#   • تخصیص IRQ affinity روی تمام هسته‌ها
# 
# نحوه استفاده:
#   با یک خط دستور (نیاز به دسترسی root یا sudo):
#   curl -fsSL https://RAW_URL/tune-net.sh | sudo bash
#
#   یا اگر فایل را دانلود کردید:
#   sudo bash tune-net.sh
#
# توجه: 
#   • برای تغییر اساسی پارامترها می‌توانید خودتان مقادیر را ویرایش کنید. 
#   • قبل از اجرا، بهتر است تست‌های iperf3 یا mtr بگیرید و بعد از اجرا هم مانیتور کنید.
#   • برای برگرداندن به تنظیمات قبلی، می‌توانید sysctl.conf را ویرایش یا پشتیبان گرفته شده را بازگردانید.
#
set -o errexit
set -o nounset
set -o pipefail

LOGFILE="/var/log/tune-net.log"

die() {
  echo -e "\e[31m[ERROR]\e[0m $1" | tee -a "$LOGFILE"
  exit 1
}

log() {
  echo -e "\e[32m[INFO]\e[0m $1" | tee -a "$LOGFILE"
}

# بررسی دسترسی root
if [ "$(id -u)" -ne 0 ]; then
  die "این اسکریپت باید با دسترسی root یا sudo اجرا شود."
fi

# -----------------------------------------------------------
# ۱. تنظیم sysctlهای بهبود شبکه
# -----------------------------------------------------------

declare -A sysctl_opts=(
  # Queueing و Congestion Control
  ["net.core.default_qdisc"]="fq"
  ["net.ipv4.netdev_default_qdisc"]="fq"
  ["net.ipv4.tcp_congestion_control"]="bbr"

  # TCP Fast Open (Client + Server)
  ["net.ipv4.tcp_fastopen"]="3"
  
  # MTU Probing (MSS/MTU کشف خودکار)
  ["net.ipv4.tcp_mtu_probing"]="1"
  
  # Window Scaling
  ["net.ipv4.tcp_window_scaling"]="1"
  
  # Backlog / SYN Queue
  ["net.core.somaxconn"]="1024"
  ["net.ipv4.tcp_max_syn_backlog"]="2048"
  ["net.core.netdev_max_backlog"]="500000"
  
  # Buffer sizes (Memory)
  ["net.core.rmem_default"]="262144"
  ["net.core.rmem_max"]="134217728"
  ["net.core.wmem_default"]="262144"
  ["net.core.wmem_max"]="134217728"
  ["net.ipv4.tcp_rmem"]="4096 87380 67108864"
  ["net.ipv4.tcp_wmem"]="4096 65536 67108864"
  
  # TIME-WAIT reuse/recycle (فقط اگر NAT ندارید)
  ["net.ipv4.tcp_tw_reuse"]="1"
  ["net.ipv4.tcp_tw_recycle"]="1"
  
  # FIN_TIMEOUT و Keepalive
  ["net.ipv4.tcp_fin_timeout"]="15"
  ["net.ipv4.tcp_keepalive_time"]="300"
  ["net.ipv4.tcp_keepalive_intvl"]="30"
  ["net.ipv4.tcp_keepalive_probes"]="5"
  
  # TCP No Metrics Save (تا congestion history پاک شود)
  ["net.ipv4.tcp_no_metrics_save"]="1"
)

log "اعمال تنظیمات sysctl..."
for key in "${!sysctl_opts[@]}"; do
  value="${sysctl_opts[$key]}"
  sysctl -w "$key=$value" >/dev/null 2>&1 || die "شکست در تنظیم $key=$value"
  # ثبت در /etc/sysctl.conf اگر تکراری نیست
  grep -qxF "$key = $value" /etc/sysctl.conf \
    || echo "$key = $value" >> /etc/sysctl.conf
done
sysctl -p >/dev/null 2>&1 || die "بارگذاری مجدد تنظیمات sysctl با خطا مواجه شد."
log "تنظیمات sysctl اعمال و ثبت شدند."

# -----------------------------------------------------------
# ۲. فعال‌سازی ماژول tcp_bbr
# -----------------------------------------------------------

log "بررسی ماژول tcp_bbr..."
if ! lsmod | grep -q '^tcp_bbr'; then
  modprobe tcp_bbr || die "بارگذاری ماژول tcp_bbr شکست خورد."
  echo "tcp_bbr" >/etc/modules-load.d/bbr.conf
  log "ماژول tcp_bbr بارگذاری و در بوت بعدی ثبت شد."
else
  log "ماژول tcp_bbr از قبل بارگذاری شده بود."
fi

# -----------------------------------------------------------
# ۳. تنظیم MTU و route خودکار (/24)
# -----------------------------------------------------------

get_iface_and_cidr() {
  local IFACE
  IFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}') \
    || die "ناتوان در یافتن اینترفیس پیش‌فرض."
  local IP_ADDR
  IP_ADDR=$(ip -4 addr show "$IFACE" | grep "inet " | awk '{print $2}' | cut -d/ -f1) \
    || die "ناتوان در خواندن IP اینترفیس $IFACE."
  local BASE
  BASE=$(echo "$IP_ADDR" | cut -d. -f1-3)
  local CIDR="${BASE}.0/24"
  echo "$IFACE" "$CIDR"
}

read IFACE CIDR < <(get_iface_and_cidr)
log "اینترفیس پیش‌فرض: $IFACE   CIDR خودکار: $CIDR"

# تنظیم MTU روی 1420
current_mtu=$(ip link show "$IFACE" | grep -oP 'mtu \K[0-9]+')
if [ "$current_mtu" != "1420" ]; then
  ip link set dev "$IFACE" mtu 1420 \
    || die "تنظیم MTU=1420 روی $IFACE با مشکل مواجه شد."
  log "MTU اینترفیس $IFACE روی 1420 تنظیم شد."
else
  log "MTU اینترفیس $IFACE از قبل روی 1420 است."
fi

# اضافه کردن route خودکار اگر وجود نداشته باشد
if ! ip route show | grep -qw "$CIDR"; then
  ip route add "$CIDR" dev "$IFACE" \
    || die "افزودن route $CIDR روی $IFACE شکست خورد."
  log "مسیر $CIDR به اینترفیس $IFACE اضافه شد."
else
  log "مسیر $CIDR از قبل وجود داشت."
fi

# -----------------------------------------------------------
# ۴. فعال/بهینه‌سازی NIC offloadها
# -----------------------------------------------------------

log "فعال‌سازی قابلیت های NIC offload (GRO, GSO, TSO, LRO) روی $IFACE..."
ethtool -K "$IFACE" gro on gso on tso on lro on \
  || log "هشدار: فعال‌سازی NIC offload روی $IFACE موفق نبود."

# -----------------------------------------------------------
# ۵. افزایش RX/TX ring buffer
# -----------------------------------------------------------

log "افزایش RX/TX ring buffer برای $IFACE..."
ethtool -G "$IFACE" rx 4096 tx 4096 \
  || log "هشدار: تنظیم ring buffer روی $IFACE موفق نبود."

# -----------------------------------------------------------
# ۶. تنظیم interrupt coalescing (coalesce)
# -----------------------------------------------------------

log "تنظیم interrupt coalescing روی $IFACE..."
ethtool -C "$IFACE" rx-usecs 50 rx-frames 64 tx-usecs 50 tx-frames 64 \
  || log "هشدار: تنظیم interrupt coalescing روی $IFACE موفق نبود."

# -----------------------------------------------------------
# ۷. تخصیص IRQ affinity برای تمام هسته‌ها
# -----------------------------------------------------------

log "تنظیم IRQ affinity برای $IFACE روی همهٔ CPUها..."
IRQLIST=$(grep -R "$IFACE" /proc/interrupts | awk -F: '{print $1}')
for irq in $IRQLIST; do
  echo f > /proc/irq/"$irq"/smp_affinity \
    || log "هشدار: عدم امکان تنظیم smp_affinity برای IRQ $irq"
done

# -----------------------------------------------------------
# ۸. خلاصه و پایان
# -----------------------------------------------------------

log "تمام تنظیمات شبکه انجام شد. برای بررسی دقیق‌تر:"
log "  • sysctl: sysctl net.ipv4.tcp_congestion_control"
log "  • MTU:     ip link show $IFACE"
log "  • Route:   ip route show | grep \"$CIDR\""
log "  • Offload: ethtool -k $IFACE"
log "  • Ringbuf: ethtool -g $IFACE"
log "  • IRQ:     grep \"$IFACE\" /proc/interrupts"

echo -e "\n\e[34m>>> Network tuning complete. لطفاً تست و مانیتورینگ را ادامه دهید.\e[0m\n"
exit 0

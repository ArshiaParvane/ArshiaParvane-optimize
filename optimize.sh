#!/bin/bash
#
# optimiser.sh
# اسکریپت بسیار ساده برای:
#   - enable: فعال کردن BBR با تنظیمات پیشرفته، MTU=1420 و اضافه کردن route خودکار /24
#   - disable: غیرفعال کردن BBR، برگرداندن MTU=1500 و حذف route خودکار /24
#
# نحوه استفاده:
#   sudo ./optimiser.sh enable
#   sudo ./optimiser.sh disable

set -o errexit
set -o nounset
set -o pipefail

LOGFILE="/var/log/optimiser.log"

die() {
  echo "[ERROR] $1" | tee -a "$LOGFILE"
  exit 1
}

log() {
  echo "[INFO ] $1" | tee -a "$LOGFILE"
}

# حتماً با دسترسی root اجرا شود
if [ "$(id -u)" -ne 0 ]; then
  die "این اسکریپت باید با sudo یا به‌عنوان root اجرا شود."
fi

# دریافت اینترفیس پیش‌فرض و CIDR خودکار (/24)
get_iface_and_cidr() {
  local IFACE
  IFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}') || die "ناتوان در یافتن اینترفیس پیش‌فرض."
  local IP_ADDR
  IP_ADDR=$(ip -4 addr show "$IFACE" | grep "inet " | awk '{print $2}' | cut -d/ -f1) \
    || die "ناتوان در خواندن IP اینترفیس $IFACE."
  local BASE
  BASE=$(echo "$IP_ADDR" | cut -d. -f1-3)
  local CIDR="${BASE}.0/24"
  echo "$IFACE" "$CIDR"
}

enable_all() {
  log "فعال‌سازی BBR و تنظیمات پیشرفته..."

  # بارگذاری ماژول BBR
  if ! lsmod | grep -q "^tcp_bbr"; then
    modprobe tcp_bbr || die "بارگذاری ماژول tcp_bbr شکست خورد."
    echo "tcp_bbr" >/etc/modules-load.d/optimiser-bbr.conf
    log "ماژول tcp_bbr بارگذاری و برای بوت آینده ذخیره شد."
  else
    log "ماژول tcp_bbr قبلاً بارگذاری شده است."
  fi

  # تنظیم sysctl‌های پیشرفته
  sysctl -w net.core.default_qdisc=fq                 || die "تنظیم default_qdisc=fq شکست خورد."
  sysctl -w net.ipv4.tcp_congestion_control=bbr       || die "تنظیم tcp_congestion_control=bbr شکست خورد."
  sysctl -w net.ipv4.tcp_fastopen=3                   || die "تنظیم tcp_fastopen شکست خورد."
  sysctl -w net.ipv4.tcp_mtu_probing=1                || die "تنظیم tcp_mtu_probing شکست خورد."
  sysctl -w net.ipv4.tcp_window_scaling=1              || die "تنظیم tcp_window_scaling شکست خورد."
  sysctl -w net.core.netdev_max_backlog=250000         || die "تنظیم netdev_max_backlog شکست خورد."
  sysctl -w net.core.rmem_max=67108864                 || die "تنظیم rmem_max شکست خورد."
  sysctl -w net.core.wmem_max=67108864                 || die "تنظیم wmem_max شکست خورد."
  sysctl -w net.ipv4.tcp_rmem="4096 87380 67108864"    || die "تنظیم tcp_rmem شکست خورد."
  sysctl -w net.ipv4.tcp_wmem="4096 65536 67108864"    || die "تنظیم tcp_wmem شکست خورد."
  sysctl -w net.ipv4.tcp_no_metrics_save=1             || die "تنظیم tcp_no_metrics_save شکست خورد."

  # ثبت دائم در /etc/sysctl.conf
  {
    grep -qxF "net.core.default_qdisc=fq" /etc/sysctl.conf            || echo "net.core.default_qdisc=fq"
    grep -qxF "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf   || echo "net.ipv4.tcp_congestion_control=bbr"
    grep -qxF "net.ipv4.tcp_fastopen=3" /etc/sysctl.conf               || echo "net.ipv4.tcp_fastopen=3"
    grep -qxF "net.ipv4.tcp_mtu_probing=1" /etc/sysctl.conf            || echo "net.ipv4.tcp_mtu_probing=1"
    grep -qxF "net.ipv4.tcp_window_scaling=1" /etc/sysctl.conf          || echo "net.ipv4.tcp_window_scaling=1"
    grep -qxF "net.core.netdev_max_backlog=250000" /etc/sysctl.conf     || echo "net.core.netdev_max_backlog=250000"
    grep -qxF "net.core.rmem_max=67108864" /etc/sysctl.conf             || echo "net.core.rmem_max=67108864"
    grep -qxF "net.core.wmem_max=67108864" /etc/sysctl.conf             || echo "net.core.wmem_max=67108864"
    grep -qxF "net.ipv4.tcp_rmem=4096 87380 67108864" /etc/sysctl.conf  || echo "net.ipv4.tcp_rmem=4096 87380 67108864"
    grep -qxF "net.ipv4.tcp_wmem=4096 65536 67108864" /etc/sysctl.conf  || echo "net.ipv4.tcp_wmem=4096 65536 67108864"
    grep -qxF "net.ipv4.tcp_no_metrics_save=1" /etc/sysctl.conf         || echo "net.ipv4.tcp_no_metrics_save=1"
  } >>/etc/sysctl.conf

  sysctl -p >/dev/null 2>&1 || die "بارگذاری مجدد تنظیمات sysctl شکست خورد."
  log "تنظیمات sysctl ثبت و اعمال شدند."

  # اضافه کردن route خودکار /24 و تنظیم MTU
  read IFACE CIDR < <(get_iface_and_cidr)
  if ! ip route show | grep -qw "$CIDR"; then
    ip route add "$CIDR" dev "$IFACE" || die "افزودن route $CIDR شکست خورد."
    log "مسیر $CIDR به اینترفیس $IFACE اضافه شد."
  else
    log "مسیر $CIDR از قبل وجود داشت."
  fi

  current_mtu=$(ip link show "$IFACE" | grep -oP 'mtu \K[0-9]+')
  if [ "$current_mtu" != "1420" ]; then
    ip link set dev "$IFACE" mtu 1420 || die "تنظیم MTU برای $IFACE شکست خورد."
    log "MTU اینترفیس $IFACE روی 1420 تنظیم شد."
  else
    log "MTU اینترفیس $IFACE همین الان هم 1420 بود."
  fi

  log "تمامی تنظیمات فعال شدند."
}

disable_all() {
  log "غیرفعال‌سازی تمام تنظیمات و بازگرداندن به حالت پیش‌فرض..."

  # حذف ماژول BBR از بوت آینده و حافظه
  sed -i '\|tcp_bbr|d' /etc/modules-load.d/optimiser-bbr.conf 2>/dev/null || true
  if lsmod | grep -q "^tcp_bbr"; then
    rmmod tcp_bbr || log "اشکال در حذف ماژول tcp_bbr از حافظه."
  fi

  # بازگرداندن sysctl های پیش‌فرض
  sysctl -w net.core.default_qdisc=pfifo_fast             || log "بازیابی default_qdisc شکست خورد."
  sysctl -w net.ipv4.tcp_congestion_control=cubic          || log "بازیابی tcp_congestion_control شکست خورد."
  sysctl -w net.ipv4.tcp_fastopen=0                        || log "بازیابی tcp_fastopen شکست خورد."
  sysctl -w net.ipv4.tcp_mtu_probing=0                     || log "بازیابی tcp_mtu_probing شکست خورد."
  sysctl -w net.ipv4.tcp_no_metrics_save=0                 || log "بازیابی tcp_no_metrics_save شکست خورد."
  # (rmem و wmem و backlog را برای سادگی دست نخورده گذاشتیم؛ در صورت نیاز دستی تنظیم کنید)

  # حذف خطوط مرتبط از /etc/sysctl.conf
  sed -i '\|net.core.default_qdisc=fq|d' /etc/sysctl.conf 2>/dev/null || true
  sed -i '\|net.ipv4.tcp_congestion_control=bbr|d' /etc/sysctl.conf 2>/dev/null || true
  sed -i '\|net.ipv4.tcp_fastopen=3|d' /etc/sysctl.conf 2>/dev/null || true
  sed -i '\|net.ipv4.tcp_mtu_probing=1|d' /etc/sysctl.conf 2>/dev/null || true
  sed -i '\|net.ipv4.tcp_window_scaling=1|d' /etc/sysctl.conf 2>/dev/null || true
  sed -i '\|net.core.netdev_max_backlog=250000|d' /etc/sysctl.conf 2>/dev/null || true
  sed -i '\|net.core.rmem_max=67108864|d' /etc/sysctl.conf 2>/dev/null || true
  sed -i '\|net.core.wmem_max=67108864|d' /etc/sysctl.conf 2>/dev/null || true
  sed -i '\|net.ipv4.tcp_rmem=4096 87380 67108864|d' /etc/sysctl.conf 2>/dev/null || true
  sed -i '\|net.ipv4.tcp_wmem=4096 65536 67108864|d' /etc/sysctl.conf 2>/dev/null || true
  sed -i '\|net.ipv4.tcp_no_metrics_save=1|d' /etc/sysctl.conf 2>/dev/null || true

  sysctl -p >/dev/null 2>&1 || log "بارگذاری مجدد تنظیمات sysctl شکست خورد."

  # حذف route خودکار و برگرداندن MTU
  read IFACE CIDR < <(get_iface_and_cidr)
  if ip route show | grep -qw "$CIDR"; then
    ip route del "$CIDR" || die "حذف route $CIDR شکست خورد."
    log "مسیر $CIDR حذف شد."
  else
    log "مسیر $CIDR اصلاً وجود نداشت."
  fi

  current_mtu=$(ip link show "$IFACE" | grep -oP 'mtu \K[0-9]+')
  if [ "$current_mtu" != "1500" ]; then
    ip link set dev "$IFACE" mtu 1500 || die "تنظیم MTU روی 1500 برای $IFACE شکست خورد."
    log "MTU اینترفیس $IFACE روی 1500 بازگردانده شد."
  else
    log "MTU همین الآن هم 1500 بود."
  fi

  log "همه‌چیز به حالت اولیه بازگشت."
}

# چک آرگومان
if [ "$#" -ne 1 ]; then
  echo "Usage: sudo $0 {enable|disable}"
  exit 1
fi

case "$1" in
  enable)
    enable_all
    ;;
  disable)
    disable_all
    ;;
  *)
    echo "Usage: sudo $0 {enable|disable}"
    exit 1
    ;;
esac

exit 0

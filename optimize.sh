#!/bin/bash

# فقط اجازه اجرا برای کاربران با نام شامل "ArshiaParvane"
AUTHORIZED_SUBSTRING="ArshiaParvane"
CURRENT_USER=$(whoami)

if [[ "$CURRENT_USER" != *"$AUTHORIZED_SUBSTRING"* ]]; then
  echo "شما اجازه اجرای این اسکریپت را ندارید."
  exit 1
fi

# پیدا کردن اینترفیس پیش‌فرض
INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')

# پیدا کردن IP اینترفیس
IP_ADDRESS=$(ip addr show "$INTERFACE" | grep "inet " | awk '{print $2}' | cut -d/ -f1)

# ساخت رنج IP /24 از IP اصلی سرور
IP_BASE=$(echo $IP_ADDRESS | cut -d. -f1-3)
DEST_IP_RANGE="${IP_BASE}.0/24"

echo "اینترفیس: $INTERFACE"
echo "IP سرور: $IP_ADDRESS"
echo "رنج IP مقصد: $DEST_IP_RANGE"

# فعال‌سازی BBR
sudo modprobe tcp_bbr
echo "tcp_bbr" | sudo tee -a /etc/modules-load.d/modules.conf

sudo sysctl -w net.core.default_qdisc=fq
sudo sysctl -w net.ipv4.tcp_congestion_control=bbr

echo "net.core.default_qdisc=fq" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# اضافه کردن روت اختصاصی اگر قبلاً نبود
if ! ip route show | grep -q "$DEST_IP_RANGE"; then
  sudo ip route add $DEST_IP_RANGE dev $INTERFACE
  echo "مسیر $DEST_IP_RANGE اضافه شد."
else
  echo "مسیر $DEST_IP_RANGE قبلاً تنظیم شده."
fi

echo "BBR فعال شد و روت اختصاصی تنظیم شد."

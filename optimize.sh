#!/bin/bash

INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
IP_ADDRESS=$(ip addr show "$INTERFACE" | grep "inet " | awk '{print $2}' | cut -d/ -f1)
IP_BASE=$(echo $IP_ADDRESS | cut -d. -f1-3)
DEST_IP_RANGE="${IP_BASE}.0/24"

echo "Interface: $INTERFACE"
echo "Server IP: $IP_ADDRESS"
echo "Destination IP range: $DEST_IP_RANGE"

sudo modprobe tcp_bbr
echo "tcp_bbr" | sudo tee -a /etc/modules-load.d/modules.conf

sudo sysctl -w net.core.default_qdisc=fq
sudo sysctl -w net.ipv4.tcp_congestion_control=bbr

echo "net.core.default_qdisc=fq" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

if ! ip route show | grep -q "$DEST_IP_RANGE"; then
  sudo ip route add $DEST_IP_RANGE dev $INTERFACE
  echo "Route $DEST_IP_RANGE added."
else
  echo "Route $DEST_IP_RANGE already exists."
fi

echo "BBR enabled and custom route set."

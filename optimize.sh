#!/bin/bash
#
# optimize.sh
# Optimized script for throughput + low-latency networking on Linux
#
# Features:
#   • sysctl tuning stored in /etc/sysctl.d/99-optimize.conf
#   • Load and persist tcp_bbr
#   • Disable NIC offloads (GRO, GSO, TSO, LRO)
#   • Reduce interrupt coalescing (1 interrupt per packet)
#   • Assign NIC IRQs to CPU core #1
#   • MTU untouched (by request)
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

if [ "$(id -u)" -ne 0 ]; then
  die "This script must be run as root."
fi

log "Starting network optimization..."

# -----------------------------------------------------------
# 1. sysctl → stored in /etc/sysctl.d/99-optimize.conf
# -----------------------------------------------------------
SYSCTL_FILE="/etc/sysctl.d/99-optimize.conf"

declare -A sysctl_opts=(
  ["net.core.default_qdisc"]="cake"
  ["net.ipv4.tcp_congestion_control"]="bbr"
  ["net.ipv4.tcp_fastopen"]="3"
  ["net.ipv4.tcp_mtu_probing"]="1"
  ["net.ipv4.tcp_window_scaling"]="1"
  ["net.core.somaxconn"]="1024"
  ["net.ipv4.tcp_max_syn_backlog"]="2048"
  ["net.core.netdev_max_backlog"]="500000"
  ["net.core.rmem_default"]="262144"
  ["net.core.rmem_max"]="134217728"
  ["net.core.wmem_default"]="262144"
  ["net.core.wmem_max"]="134217728"
  ["net.ipv4.tcp_rmem"]="4096 87380 67108864"
  ["net.ipv4.tcp_wmem"]="4096 65536 67108864"
  ["net.ipv4.tcp_tw_reuse"]="1"
  ["net.ipv4.tcp_fin_timeout"]="15"
  ["net.ipv4.tcp_keepalive_time"]="300"
  ["net.ipv4.tcp_keepalive_intvl"]="30"
  ["net.ipv4.tcp_keepalive_probes"]="5"
  ["net.ipv4.tcp_no_metrics_save"]="1"
)

log "Writing sysctl config to $SYSCTL_FILE ..."
: > "$SYSCTL_FILE"
for key in "${!sysctl_opts[@]}"; do
  value="${sysctl_opts[$key]}"
  if sysctl -w "$key=$value" >/dev/null 2>&1; then
    echo "$key = $value" >> "$SYSCTL_FILE"
    log "Applied: $key = $value"
  else
    if [[ "$key" == "net.core.default_qdisc" ]]; then
      fallback="fq_codel"
      sysctl -w "$key=$fallback" >/dev/null 2>&1 || die "Failed to set $key"
      echo "$key = $fallback" >> "$SYSCTL_FILE"
      log "Fallback applied: $key = $fallback"
    else
      die "Failed to apply sysctl: $key=$value"
    fi
  fi
done
sysctl --system >/dev/null 2>&1
log "Sysctl parameters applied and persisted."

# -----------------------------------------------------------
# 2. Load tcp_bbr
# -----------------------------------------------------------
log "Loading tcp_bbr..."
if ! lsmod | grep -q '^tcp_bbr'; then
  modprobe tcp_bbr || die "Failed to load tcp_bbr module."
  echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
  log "tcp_bbr loaded and persisted."
else
  log "tcp_bbr is already loaded."
fi

# -----------------------------------------------------------
# 3. Detect default network interface
# -----------------------------------------------------------
get_iface() {
  ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}' \
    || die "Unable to detect default interface."
}
IFACE=$(get_iface)
log "Default interface: $IFACE"

# -----------------------------------------------------------
# 4. Create systemd service for NIC tuning
# -----------------------------------------------------------
SERVICE_FILE="/etc/systemd/system/net-optimize.service"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Network optimizations (offload, coalescing, IRQ affinity)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/ethtool -K $IFACE gro off gso off tso off lro off
ExecStart=/usr/bin/ethtool -C $IFACE rx-usecs 0 rx-frames 1 tx-usecs 0 tx-frames 1
ExecStart=/bin/bash -c 'for irq in \$(grep "$IFACE" /proc/interrupts | awk -F: "{gsub(/^[ \\t]+/,\\"\\",\$1); print \$1}"); do echo 2 > /proc/irq/\$irq/smp_affinity; done'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now net-optimize.service
log "Systemd service created and enabled for NIC tuning."

# -----------------------------------------------------------
# 5. Summary
# -----------------------------------------------------------
log "All optimizations applied."
log "Check status with:"
log "  sysctl -a | grep qdisc"
log "  sysctl net.ipv4.tcp_congestion_control"
log "  ethtool -k $IFACE | grep -E 'gro|gso|tso|lro'"
log "  ethtool -c $IFACE"
log "  grep \"$IFACE\" /proc/interrupts"

echo -e "\n\e[34m>>> Optimization complete. Test with ping and iperf3.\e[0m\n"
exit 0

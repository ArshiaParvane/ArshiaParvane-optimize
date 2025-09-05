#!/usr/bin/env bash
# all-in-one linux tuning: network + system + pretty UI (English output)
set -Eeuo pipefail
IFS=$'\n\t'

# -------------------- Config --------------------
MTU_DEFAULT="1420"                                  # set "" to skip changing MTU
MTU_CRON_TAG="# mtu1420-all"
BBR_SYSCTL="/etc/sysctl.d/10-bbr.conf"
NET_SYSCTL="/etc/sysctl.d/15-net-basics.conf"
VM_SYSCTL="/etc/sysctl.d/20-vm.conf"
LIMITS_FILE="/etc/security/limits.d/99-openfiles.conf"
THP_SERVICE="/etc/systemd/system/disable-thp.service"
UDEV_SCHED="/etc/udev/rules.d/60-io-scheduler.rules"

# -------------------- Helpers --------------------
ok(){ echo -e "[OK] $*"; }
warn(){ echo -e "[WARN] $*" >&2; }
err(){ echo -e "[ERROR] $*" >&2; }
have(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [[ $(id -u) -eq 0 ]] || { err "Run as root."; exit 1; }; }
first_iface(){ ls /sys/class/net | grep -vE '^(lo|docker|veth)' | head -n1 || true; }

# -------------------- MTU (runtime + cron) --------------------
set_mtu_all(){
  local mtu="${1:-$MTU_DEFAULT}"
  [[ -z "$mtu" ]] && { warn "MTU change skipped (empty)."; return 0; }
  local changed=0
  for iface in $(ls /sys/class/net | grep -v '^lo$'); do
    ip link set dev "$iface" mtu "$mtu" 2>/dev/null && { ok "Set MTU=$mtu on $iface"; changed=$((changed+1)); } || warn "Could not set MTU on $iface"
  done
  (( changed > 0 )) || warn "No MTU changes were applied."
}

persist_mtu_cron(){
  local mtu="${1:-$MTU_DEFAULT}"
  [[ -z "$mtu" ]] && return 0
  local line="@reboot for iface in \$(ls /sys/class/net | grep -v lo); do ip link set dev \"\$iface\" mtu $mtu; done $MTU_CRON_TAG"
  # idempotent insert
  ( crontab -l 2>/dev/null | grep -Fv "$MTU_CRON_TAG"; echo "$line" ) | crontab - && ok "Installed @reboot MTU=$mtu for all non-lo interfaces"
}

# -------------------- BBR + net sysctls --------------------
enable_bbr_sysctl(){
  local qdisc="fq"
  modprobe -n -v sch_fq >/dev/null 2>&1 || qdisc="fq_codel"

  # load tcp_bbr now and persist if available
  if modprobe -n -v tcp_bbr >/dev/null 2>&1; then
    modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" >/etc/modules-load.d/bbr.conf 2>/dev/null || true
    ok "tcp_bbr module loaded and persisted"
  else
    warn "tcp_bbr module not available (will fall back to cubic if needed)"
  fi

  cat >"$BBR_SYSCTL" <<EOF
# BBR core
net.core.default_qdisc = ${qdisc}
net.ipv4.tcp_congestion_control = bbr
# safe helpers
net.ipv4.tcp_fastopen = 1
net.ipv4.tcp_mtu_probing = 1
EOF
  sysctl -p "$BBR_SYSCTL" >/dev/null 2>&1 || true
  ok "Applied BBR sysctls (qdisc=${qdisc})"
}

apply_net_basics(){
  cat >"$NET_SYSCTL" <<'EOF'
# reasonable queue/backlog knobs (conservative)
net.core.somaxconn = 2048
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 32768
EOF
  sysctl -p "$NET_SYSCTL" >/dev/null 2>&1 || true
  ok "Applied baseline network sysctls"
}

# -------------------- System resources --------------------
set_ulimits(){
  # runtime for current shell (best-effort)
  ulimit -n 65535 2>/dev/null || true
  # persistent for logins/services
  cat >"$LIMITS_FILE" <<'EOF'
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF
  ok "Set open files limit (nofile) to 65535 via limits.d"
}

set_vm_tunables(){
  cat >"$VM_SYSCTL" <<'EOF'
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
  sysctl -p "$VM_SYSCTL" >/dev/null 2>&1 || true
  ok "Applied VM tunables (swappiness=10, vfs_cache_pressure=50)"
}

disable_thp(){
  # runtime
  for f in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do
    [[ -w "$f" ]] && echo never > "$f" 2>/dev/null || true
  done
  # persistent service
  cat >"$THP_SERVICE" <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages (THP)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash -c 'for f in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do [[ -w "$f" ]] && echo never > "$f" || true; done'

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now disable-thp.service >/dev/null 2>&1 || true
  ok "Disabled THP (runtime + systemd service)"
}

install_io_scheduler_udev(){
  # sets mq-deadline for non-rotational devices at boot (if available)
  cat >"$UDEV_SCHED" <<'EOF'
ACTION=="add|change", KERNEL=="sd*[!0-9]", ATTR{queue/rotational}=="0", TEST=="queue/scheduler", RUN+="/usr/bin/bash -c 'if grep -qw mq-deadline /sys/block/%k/queue/scheduler; then echo mq-deadline > /sys/block/%k/queue/scheduler; fi'"
EOF
  # apply now (best-effort)
  for d in /sys/block/*; do
    [[ -f "$d/queue/rotational" ]] || continue
    if [[ "$(cat "$d/queue/rotational")" -eq 0 ]] && [[ -w "$d/queue/scheduler" ]] && grep -qw mq-deadline "$d/queue/scheduler"; then
      echo mq-deadline > "$d/queue/scheduler" 2>/dev/null || true
    fi
  done
  udevadm control --reload >/dev/null 2>&1 || true
  ok "Configured I/O scheduler (mq-deadline for SSD where supported)"
}

# -------------------- UI Panel --------------------
ui_panel(){
  local iface="$(first_iface)"
  local qdisc cc swp vfs thp
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  swp=$(sysctl -n vm.swappiness 2>/dev/null || echo "?")
  vfs=$(sysctl -n vm.vfs_cache_pressure 2>/dev/null || echo "?")
  thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | sed -E 's/.*\[(.*)\].*/\1/' || echo "?")

  # gather MTUs
  local MTU_LINES=""
  for i in $(ls /sys/class/net | grep -v '^lo$'); do
    local m; m=$(ip -o link show "$i" 2>/dev/null | awk '{for(j=1;j<=NF;j++) if($j=="mtu") print $(j+1)}')
    MTU_LINES+="$i: ${m:-?}   "
  done

  # gather IO sched
  local IOS=""
  for d in /sys/block/*; do
    [[ -f "$d/queue/scheduler" ]] || continue
    local name sched; name=$(basename "$d"); sched=$(tr -d '[]' < "$d/queue/scheduler")
    IOS+="$name: $sched   "
  done

  local W=74; local SEP; SEP=$(printf '%*s' "$W" '' | tr ' ' '─')
  echo "┌${SEP}┐"
  printf "│ %-*s │\n" "$W" "Linux Optimize Summary"
  echo "├${SEP}┤"
  printf "│ %-*s │\n" "$W" "Network"
  printf "│ %-*s │\n" "$W" "  qdisc=$qdisc   cc=$cc"
  printf "│ %-*s │\n" "$W" "  MTUs: $MTU_LINES"
  echo "├${SEP}┤"
  printf "│ %-*s │\n" "$W" "System"
  printf "│ %-*s │\n" "$W" "  swappiness=$swp   vfs_cache_pressure=$vfs   THP=$thp"
  printf "│ %-*s │\n" "$W" "  nofile target: 65535 (limits.d)"
  printf "│ %-*s │\n" "$W" "  IO sched: $IOS"
  echo "└${SEP}┘"
}

# -------------------- Main --------------------
main(){
  need_root

  echo "[1/6] Set MTU for all interfaces …"
  set_mtu_all "$MTU_DEFAULT"
  persist_mtu_cron "$MTU_DEFAULT"

  echo "[2/6] Enable BBR + net qdisc …"
  enable_bbr_sysctl
  apply_net_basics

  echo "[3/6] Set process/file limits …"
  set_ulimits

  echo "[4/6] Apply VM tunables …"
  set_vm_tunables

  echo "[5/6] Disable THP …"
  disable_thp

  echo "[6/6] Configure IO scheduler …"
  install_io_scheduler_udev

  echo "✅ Done. Summary:"
  ui_panel
}

main "$@"

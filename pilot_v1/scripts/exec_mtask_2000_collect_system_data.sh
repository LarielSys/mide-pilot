#!/usr/bin/env bash
set -uo pipefail

echo task=MTASK-2000
echo objective=collect_system_data_for_website_integration
echo timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="${REPO_ROOT}/pilot_v1/state/website_system_data.json"

# ── 1. Hostname and basic info ─────────────────────────────────────────────────
echo "--- system_info ---"
HOSTNAME=$(hostname)
echo hostname="$HOSTNAME"
FQDN=$(hostname -f)
echo fqdn="$FQDN"
KERNEL=$(uname -r)
echo kernel="$KERNEL"
DISTRO=$(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)
echo distro="$DISTRO"

# ── 2. Network interfaces and IPs ─────────────────────────────────────────────
echo "--- network_interfaces ---"
ip link show | grep "^[0-9]" | while read line; do
  iface=$(echo "$line" | awk '{print $2}' | tr -d ':')
  state=$(echo "$line" | grep -o "UP\|DOWN" | head -1)
  ip_addr=$(ip addr show "$iface" 2>/dev/null | grep "inet " | awk '{print $2}' | head -1)
  echo "  interface: $iface state=$state ip=$ip_addr"
done

# ── 3. Public IP (if available) ───────────────────────────────────────────────
echo "--- public_ip ---"
PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "unavailable")
echo public_ip="$PUBLIC_IP"

# ── 4. DNS resolver ───────────────────────────────────────────────────────────
echo "--- dns_config ---"
if [[ -f /etc/resolv.conf ]]; then
  NAMESERVERS=$(grep -h "^nameserver" /etc/resolv.conf | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
  echo nameservers="$NAMESERVERS"
fi

# ── 5. Listening ports and services ───────────────────────────────────────────
echo "--- listening_ports ---"
ss -tlnp 2>/dev/null | tail -n +2 | while read line; do
  proto=$(echo "$line" | awk '{print $1}')
  local=$(echo "$line" | awk '{print $4}')
  state=$(echo "$line" | awk '{print $2}')
  program=$(echo "$line" | awk '{print $NF}' | sed 's|.*/||')
  port=$(echo "$local" | awk -F: '{print $NF}')
  echo "  $proto $local $state $program"
done

# ── 6. Established connections ────────────────────────────────────────────────
echo "--- established_connections ---"
CONN_COUNT=$(ss -tn state established 2>/dev/null | tail -n +2 | wc -l)
echo established_connections=$CONN_COUNT
ss -tn state established 2>/dev/null | tail -n +2 | head -20 | while read line; do
  local_addr=$(echo "$line" | awk '{print $4}')
  remote_addr=$(echo "$line" | awk '{print $5}')
  echo "  $local_addr <-> $remote_addr"
done

# ── 7. Resource usage ─────────────────────────────────────────────────────────
echo "--- resource_usage ---"
LOAD=$(uptime | awk -F'load average:' '{print $2}')
echo load_average="$LOAD"

MEM_INFO=$(free -h | grep Mem)
MEM_TOTAL=$(echo "$MEM_INFO" | awk '{print $2}')
MEM_USED=$(echo "$MEM_INFO" | awk '{print $3}')
MEM_AVAIL=$(echo "$MEM_INFO" | awk '{print $7}')
echo "  memory_total=$MEM_TOTAL memory_used=$MEM_USED memory_available=$MEM_AVAIL"

DISK_INFO=$(df -h / | tail -1)
DISK_SIZE=$(echo "$DISK_INFO" | awk '{print $2}')
DISK_USED=$(echo "$DISK_INFO" | awk '{print $3}')
DISK_AVAIL=$(echo "$DISK_INFO" | awk '{print $4}')
DISK_PCT=$(echo "$DISK_INFO" | awk '{print $5}')
echo "  disk_size=$DISK_SIZE disk_used=$DISK_USED disk_available=$DISK_AVAIL disk_used_percent=$DISK_PCT"

# ── 8. Active services summary ────────────────────────────────────────────────
echo "--- services_summary ---"
systemctl is-active ollama 2>/dev/null && echo "  ollama: active" || echo "  ollama: inactive"
systemctl is-active customide 2>/dev/null && echo "  customide: active" || echo "  customide: inactive"
docker ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null | tail -n +2 | head -10 | while read name status; do
  echo "  docker: $name = $status"
done

# ── 9. Write comprehensive JSON for website ───────────────────────────────────
echo "--- writing_state_file ---"
python3 - "$STATE_FILE" "$HOSTNAME" "$FQDN" "$PUBLIC_IP" "$MEM_TOTAL" "$MEM_USED" "$DISK_SIZE" "$DISK_USED" <<'PY'
import json, sys, pathlib, datetime, socket, subprocess

state_file, hostname, fqdn, public_ip, mem_total, mem_used, disk_size, disk_used = sys.argv[1:9]

# Get all IP addresses
ips = []
try:
    result = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=5)
    ips = result.stdout.strip().split()
except:
    pass

# Get listening ports
ports = {}
try:
    result = subprocess.run(["ss", "-tlnp"], capture_output=True, text=True, timeout=5)
    for line in result.stdout.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 4:
            proto = parts[0]
            local_addr = parts[3]
            port = local_addr.split(":")[-1]
            ports[port] = {"proto": proto, "local": local_addr}
except:
    pass

data = {
    "collected_utc": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "collected_by": "MTASK-2000",
    "system": {
        "hostname": hostname,
        "fqdn": fqdn,
    },
    "network": {
        "local_ips": ips,
        "public_ip": public_ip,
    },
    "resources": {
        "memory_total": mem_total,
        "memory_used": mem_used,
        "disk_total": disk_size,
        "disk_used": disk_used,
    },
    "ports": ports,
}

p = pathlib.Path(state_file)
p.write_text(json.dumps(data, indent=2) + "\n")
print(f"state_file_written={state_file}")
print(f"entries_captured: ips={len(ips)}, ports={len(ports)}")
PY

git -C "$REPO_ROOT" add pilot_v1/state/website_system_data.json
git -C "$REPO_ROOT" commit -m "worker: MTASK-2000 system data collected for website" || true
git -C "$REPO_ROOT" push origin main || true

echo snapshot=complete

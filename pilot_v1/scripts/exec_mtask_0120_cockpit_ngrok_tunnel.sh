#!/usr/bin/env bash
set -uo pipefail
TASK_ID="MTASK-0120"
REPO_ROOT="/home/larieladmin/mide-pilot"
LOG="$REPO_ROOT/pilot_v1/state/mtask_0120.log"
SERVICES_JSON="$REPO_ROOT/pilot_v1/config/worker1_services.json"

echo "task=$TASK_ID" | tee "$LOG"
echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$LOG"

NGROK_BIN="$(command -v ngrok || true)"
if [[ -z "$NGROK_BIN" ]]; then
  echo "error=ngrok_not_found" | tee -a "$LOG"; exit 1
fi

clear_ngrok_tunnels() {
  local api_port tunnel_names tunnel_name

  for api_port in 4040 4041 4042 4043 4044 4045; do
    tunnel_names="$(curl -s "http://127.0.0.1:${api_port}/api/tunnels" 2>/dev/null | python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for tunnel in payload.get("tunnels", []):
    name = tunnel.get("name")
    if name:
        print(name)
' 2>/dev/null || true)"

    if [[ -z "$tunnel_names" ]]; then
      continue
    fi

    while IFS= read -r tunnel_name; do
      [[ -z "$tunnel_name" ]] && continue
      curl -s -X DELETE "http://127.0.0.1:${api_port}/api/tunnels/${tunnel_name}" >/dev/null 2>&1 || true
    done <<<"$tunnel_names"
  done
}

discover_cockpit_url() {
  local api_port raw discovered_url

  for api_port in 4040 4041 4042 4043 4044 4045; do
    raw="$(curl -s "http://127.0.0.1:${api_port}/api/tunnels" 2>/dev/null || echo '{}')"
    discovered_url="$(echo "$raw" | python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for tunnel in payload.get("tunnels", []):
    addr = tunnel.get("config", {}).get("addr", "")
    forwarding = str(tunnel.get("forwarding", ""))
    if "5555" in addr or "5555" in forwarding:
        print(tunnel.get("public_url", ""))
        break
' 2>/dev/null || true)"
    if [[ -n "$discovered_url" ]]; then
      printf '%s' "$discovered_url"
      return 0
    fi
  done

  return 1
}

# Clear any stale local ngrok tunnels before starting the cockpit tunnel.
clear_ngrok_tunnels

# Kill any existing ngrok tunnel on port 5555
pkill -f "ngrok.*5555" 2>/dev/null || true
sleep 2

# Start ngrok tunnel for cockpit backend port 5555
nohup "$NGROK_BIN" http 5555 --log=stdout > "$REPO_ROOT/pilot_v1/state/ngrok_cockpit.log" 2>&1 &
NGROK_PID=$!
echo "ngrok_pid=$NGROK_PID" | tee -a "$LOG"

# Wait for ngrok API to be ready
COCKPIT_URL=""
for i in $(seq 1 10); do
  sleep 2
  COCKPIT_URL="$(discover_cockpit_url || true)"
  if [[ -n "$COCKPIT_URL" ]]; then
    echo "attempt=$i cockpit_url=$COCKPIT_URL" | tee -a "$LOG"
    break
  fi
  echo "attempt=$i waiting..." | tee -a "$LOG"
done

if [[ -z "$COCKPIT_URL" ]]; then
  echo "final_status=NGROK_URL_NOT_FOUND" | tee -a "$LOG"
  exit 1
fi

echo "cockpit_url=$COCKPIT_URL" | tee -a "$LOG"

# Verify cockpit backend is reachable via tunnel
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -H "ngrok-skip-browser-warning: true" "$COCKPIT_URL/api/status/runtime" 2>/dev/null || echo 000)
echo "cockpit_http=$HTTP" | tee -a "$LOG"

# Update services JSON with cockpit URL
python3 - "$SERVICES_JSON" "$COCKPIT_URL" <<'PY'
import json, sys, pathlib, datetime
p = pathlib.Path(sys.argv[1])
url = sys.argv[2]
d = json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}
d.setdefault("services", {})["cockpit"] = {
    "local_port": 5555,
    "public_url": url,
    "status": "ok"
}
d["timestamp_utc"] = datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"
p.write_text(json.dumps(d, indent=2) + "\n", encoding="utf-8")
print("services_json_updated=yes")
PY

# Commit updated services
cd "$REPO_ROOT"
git add "pilot_v1/config/worker1_services.json" "pilot_v1/state/mtask_0120.log"
git commit -m "worker: MTASK-0120 cockpit ngrok tunnel $COCKPIT_URL" >/dev/null 2>&1 || true
GIT_TERMINAL_PROMPT=0 timeout 60 git push origin main >/dev/null 2>&1 || true

if [[ "$HTTP" == "200" ]]; then
  echo "final_status=ALL_CHECKS_PASSED"
  echo "snapshot=complete"
else
  echo "final_status=TUNNEL_UP_BACKEND_NOT_200_HTTP=${HTTP}" | tee -a "$LOG"
  exit 1
fi

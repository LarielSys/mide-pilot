#!/usr/bin/env bash
set -euo pipefail

echo "task=MTASK-0103"
echo "objective=write_services_manifest_and_final_verify"
echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

REPO_ROOT="/home/larieladmin/mide-pilot"
STATE_DIR="${REPO_ROOT}/pilot_v1/state"
MANIFEST="${STATE_DIR}/worker1_services.json"

# Final health check - all ports
declare -A PORTS=(
  [customide_backend]=5555
  [customide_frontend]=5570
  [itheia_llm]=8082
  [code_server]=8092
  [ollama]=11434
)

# Re-verify each service
RESULTS="{}"
ALL_UP=true
for SVC in "${!PORTS[@]}"; do
  PORT="${PORTS[$SVC]}"
  CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:${PORT} 2>/dev/null || echo "000")
  echo "${SVC}_port${PORT}=${CODE}"
  if [[ "$CODE" == "000" ]]; then
    ALL_UP=false
    echo "${SVC}_status=DOWN"
  else
    echo "${SVC}_status=UP"
  fi
done

# Ollama model confirm
OLLAMA_OK=$(curl -s http://127.0.0.1:11434/api/tags 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); names=[m['name'] for m in d.get('models',[])]; print(','.join(names))" 2>/dev/null || echo "unavailable")
echo "ollama_models_confirmed=${OLLAMA_OK}"

# Write manifest
python3 - <<'PYEOF'
import json, subprocess, datetime, os

def http_check(port):
    try:
        import urllib.request
        r = urllib.request.urlopen(f"http://127.0.0.1:{port}", timeout=3)
        return str(r.getcode())
    except Exception as e:
        return "000"

services = {
    "customide_backend":  {"port": 5555, "path": "pilot_v1/customide/backend", "start_cmd": "uvicorn app.main:app --host 0.0.0.0 --port 5555"},
    "customide_frontend": {"port": 5570, "path": "pilot_v1/customide/frontend", "start_cmd": "npm start or serve"},
    "itheia_llm":         {"port": 8082, "path": "/home/larieladmin/Documents/itheia-llm/server.py", "start_cmd": "python3 server.py"},
    "code_server":        {"port": 8092, "path": "~/.local/lib/code-server-4.117.0", "start_cmd": "code-server --bind-addr 0.0.0.0:8092"},
    "ollama":             {"port": 11434, "path": "/usr/local/bin/ollama", "start_cmd": "ollama serve"},
}

manifest = {
    "last_verified": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "verified_by": "MTASK-0103",
    "worker": "ubuntu-worker-01",
    "hostname": "lariel-cloud",
    "services": {}
}

for name, svc in services.items():
    code = http_check(svc["port"])
    manifest["services"][name] = {
        "port": svc["port"],
        "http_code": code,
        "status": "UP" if code != "000" else "DOWN",
        "path": svc["path"],
        "start_cmd": svc["start_cmd"]
    }

state_dir = "/home/larieladmin/mide-pilot/pilot_v1/state"
os.makedirs(state_dir, exist_ok=True)
out = f"{state_dir}/worker1_services.json"
with open(out, "w") as f:
    json.dump(manifest, f, indent=2)
print(f"manifest_written={out}")
print(f"services_up={sum(1 for s in manifest['services'].values() if s['status']=='UP')}/{len(manifest['services'])}")
PYEOF

# Commit manifest to git
cd "$REPO_ROOT"
git add pilot_v1/state/worker1_services.json
git commit -m "MTASK-0103: update worker1_services.json - verified $(date -u +%Y-%m-%d)" 2>&1 | tail -2
git push origin main 2>&1 | tail -2

DISK=$(df -h / | tail -1 | awk '{print $5}')
echo "final_disk=${DISK}"

if $ALL_UP; then
  echo "final_status=ALL_SERVICES_UP"
else
  echo "final_status=SOME_SERVICES_DOWN_SEE_ABOVE"
fi

echo "snapshot=complete"

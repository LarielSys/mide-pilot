#!/usr/bin/env bash
set -euo pipefail

echo "task=MTASK-0101"
echo "objective=full_stack_snapshot"
echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "worker=$(hostname)"

# Check all known ports
for PORT in 5555 5570 8082 8092 11434 8091; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:${PORT} 2>/dev/null || echo "000")
  echo "port${PORT}=${STATUS}"
done

# Ollama model check
OLLAMA_MODELS=$(curl -s http://127.0.0.1:11434/api/tags 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(','.join(m['name'] for m in d.get('models',[])))" 2>/dev/null || echo "unavailable")
echo "ollama_models=${OLLAMA_MODELS}"

# Search for anything using port 8091
PORT_8091_PID=$(lsof -ti tcp:8091 2>/dev/null | head -1 || echo "")
PORT_8091_CMD=$(ps -p "$PORT_8091_PID" -o cmd= 2>/dev/null || echo "nothing")
echo "port8091_pid=${PORT_8091_PID:-none}"
echo "port8091_cmd=${PORT_8091_CMD}"

# Search repo for any python file referencing 8091
REPO_ROOT="/home/larieladmin/mide-pilot"
REFS_8091=$(grep -rl "8091" "$REPO_ROOT" --include="*.py" --include="*.json" --include="*.sh" 2>/dev/null | grep -v "__pycache__" | head -10 || echo "none")
echo "repo_refs_8091=${REFS_8091}"

# Search home dir for 8091 references outside repo
HOME_REFS=$(grep -rl "8091" /home/larieladmin --include="*.py" 2>/dev/null | grep -v "__pycache__" | grep -v "mide-pilot" | head -5 || echo "none")
echo "home_refs_8091=${HOME_REFS}"

# Disk usage
DISK=$(df -h /dev/mapper/ubuntu--vg-ubuntu--lv 2>/dev/null | tail -1 | awk '{print $5}' || df -h / | tail -1 | awk '{print $5}')
echo "disk_used=${DISK}"

# Running python/node processes summary
PROCS=$(ps aux | grep -E "python3|node|uvicorn|flask" | grep -v grep | awk '{print $11}' | sort -u | tr '\n' ',' || echo "none")
echo "active_procs=${PROCS}"

echo "snapshot=complete"

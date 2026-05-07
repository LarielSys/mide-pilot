#!/usr/bin/env bash
# MTASK-0114 — Diagnose Python venv + port-5555 process survival on Ubuntu
set -uo pipefail

TASK_ID="MTASK-0114"
REPO_ROOT="/home/larieladmin/Documents/itheia-llm/MIDE"
LOG="$REPO_ROOT/pilot_v1/state/mtask_0114.log"

echo "task=$TASK_ID" | tee "$LOG"
echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$LOG"

# --- 1. Find all Python venvs ---
echo "--- venv_search ---" | tee -a "$LOG"
find /home/larieladmin -name activate -path "*/bin/activate" 2>/dev/null | head -20 | tee -a "$LOG"

# --- 2. Check which venv has fastapi ---
echo "--- fastapi_check ---" | tee -a "$LOG"
find /home/larieladmin -name activate -path "*/bin/activate" 2>/dev/null | head -10 | while read -r act; do
  python_bin="$(dirname "$act")/python"
  if [ -f "$python_bin" ]; then
    result=$("$python_bin" -c "import fastapi; print(fastapi.__version__)" 2>/dev/null || echo "NOT_INSTALLED")
    echo "venv=$act fastapi=$result" | tee -a "$LOG"
  fi
done

# --- 3. Check system python fastapi ---
echo "--- system_python ---" | tee -a "$LOG"
which python3 | tee -a "$LOG"
python3 -c "import fastapi; print('fastapi=', fastapi.__version__)" 2>/dev/null | tee -a "$LOG" || echo "system_python_fastapi=NOT_INSTALLED" | tee -a "$LOG"
which uvicorn 2>/dev/null | tee -a "$LOG" || echo "uvicorn_in_PATH=not_found" | tee -a "$LOG"

# --- 4. Port 5555 current state ---
echo "--- port_5555_before_kill ---" | tee -a "$LOG"
lsof -ti :5555 2>/dev/null | tee -a "$LOG" || echo "nothing_on_5555" | tee -a "$LOG"
ps aux | grep -E "[u]vicorn|[g]unicorn" | head -5 | tee -a "$LOG"

# --- 5. Check for process managers ---
echo "--- process_managers ---" | tee -a "$LOG"
pm2 list 2>/dev/null | head -10 | tee -a "$LOG" || echo "pm2=not_found" | tee -a "$LOG"
supervisorctl status 2>/dev/null | head -10 | tee -a "$LOG" || echo "supervisor=not_found" | tee -a "$LOG"
systemctl list-units --type=service --state=running 2>/dev/null | grep -iE "uvicorn|fastapi|cockpit|custom" | tee -a "$LOG" || echo "systemd_match=none" | tee -a "$LOG"

# --- 6. Check .git location from backend perspective ---
echo "--- git_root_check ---" | tee -a "$LOG"
BACKEND_DIR="$REPO_ROOT/pilot_v1/customide/backend"
cd "$BACKEND_DIR" 2>/dev/null && git rev-parse --show-toplevel 2>&1 | tee -a "$LOG"

# Also show what Python sees walking up for .git
python3 - <<'PY' 2>&1 | tee -a "$LOG"
from pathlib import Path
p = Path("/home/larieladmin/Documents/itheia-llm/MIDE/pilot_v1/customide/backend/app/routes/runtime.py")
print("Checking parents for .git:")
for i, parent in enumerate(p.parents):
    has_git = (parent / ".git").exists()
    git_type = "DIR" if (parent / ".git").is_dir() else ("FILE" if (parent / ".git").is_file() else "NO")
    print(f"  parents[{i}] = {parent}  .git={git_type}")
    if has_git:
        print(f"  *** FOUND .git at parents[{i}] = {parent}")
        break
    if i > 8:
        break
PY

echo "final_status=DIAGNOSIS_COMPLETE" | tee -a "$LOG"

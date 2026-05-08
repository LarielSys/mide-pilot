#!/usr/bin/env bash
# RULE: No git push from executor. Autopilot handles all git operations.
set -euo pipefail

TASK_ID="MTASK-0143"
REPO="/home/larieladmin/mide-pilot"
CUSTOMIDE="${REPO}/pilot_v1/customide"

echo "[${TASK_ID}] start $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "[${TASK_ID}] objective: force-sync cockpit backend route files from origin/main and verify /api/mtask"

cd "${REPO}"
echo "[${TASK_ID}] repo_head_before=$(git rev-parse --short HEAD || true)"

git fetch origin main 2>/dev/null || true
git checkout origin/main -- \
  pilot_v1/customide/backend/app/main.py \
  pilot_v1/customide/backend/app/routes/messenger.py \
  pilot_v1/customide/backend/app/routes/mtask.py

echo "[${TASK_ID}] synced target files from origin/main"

cd "${CUSTOMIDE}"

echo "[${TASK_ID}] host source proof (main.py import line):"
grep -n "from \.routes import" backend/app/main.py | head -1 || true
echo "[${TASK_ID}] host source proof (router include):"
grep -n "include_router(mtask.router)" backend/app/main.py || true
echo "[${TASK_ID}] host source proof (mtask route file exists):"
ls -l backend/app/routes/mtask.py || true

echo "[${TASK_ID}] host python route introspection before build:"
(cd backend && python3 - <<'PY'
from app.main import app
paths = sorted({getattr(r, 'path', '') for r in app.router.routes})
print('host_mtask_routes=', [p for p in paths if p.startswith('/api/mtask')])
PY
)

echo "[${TASK_ID}] rebuilding backend (no-cache) and recreating container..."
docker compose build --no-cache backend 2>&1 | tail -30
docker compose up -d --force-recreate backend 2>&1 | tail -20
sleep 8

echo "[${TASK_ID}] container route introspection after rebuild:"
docker compose exec -T backend python - <<'PY'
from app.main import app
paths = sorted({getattr(r, 'path', '') for r in app.router.routes})
print('container_mtask_routes=', [p for p in paths if p.startswith('/api/mtask')])
PY

HEALTH_CODE="$(curl -s -o /tmp/${TASK_ID}_health.json -w "%{http_code}" http://localhost:5555/health || true)"
PENDING_CODE="$(curl -s -o /tmp/${TASK_ID}_pending.json -w "%{http_code}" http://localhost:5555/api/mtask/pending || true)"

echo "[${TASK_ID}] health_http=${HEALTH_CODE}"
echo "[${TASK_ID}] pending_http=${PENDING_CODE}"

if [[ "${HEALTH_CODE}" != "200" ]]; then
  echo "[${TASK_ID}] backend health failed"
  exit 1
fi

if [[ "${PENDING_CODE}" != "200" ]]; then
  echo "[${TASK_ID}] mtask endpoint still not available"
  exit 1
fi

PROPOSE_PAYLOAD='{"text":"MTASK-0143 smoke proposal","issued_by":"cockpit-ai","source":"cockpit","session_id":"mtask-0143"}'
PROPOSE_RAW="$(curl -s -X POST http://localhost:5555/api/mtask/propose -H 'Content-Type: application/json' -d "${PROPOSE_PAYLOAD}" || true)"
echo "[${TASK_ID}] propose_raw=${PROPOSE_RAW}"

echo "${PROPOSE_RAW}" | python3 - <<'PY'
import sys, json
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print('proposal_parse_error')
    raise SystemExit(1)
pid = d.get('proposal_id', '')
if not pid:
    print('proposal_missing_id')
    raise SystemExit(1)
print('proposal_id=' + pid)
PY

echo "[${TASK_ID}] complete"
exit 0

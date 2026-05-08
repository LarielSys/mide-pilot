#!/usr/bin/env bash
# RULE: No git push from executor. Autopilot handles all git operations.
set -euo pipefail

TASK_ID="MTASK-0142"
REPO="/home/larieladmin/mide-pilot"
CUSTOMIDE="${REPO}/pilot_v1/customide"

echo "[${TASK_ID}] start $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "[${TASK_ID}] objective: fix /api/mtask/pending 404 on cockpit backend"

cd "${CUSTOMIDE}"

echo "[${TASK_ID}] hard rebuilding backend image (no cache)..."
docker compose build --no-cache backend 2>&1 | tail -30
docker compose up -d --force-recreate backend 2>&1 | tail -20
sleep 8

HEALTH_CODE="$(curl -s -o /tmp/${TASK_ID}_health.json -w "%{http_code}" http://localhost:5555/health || true)"
MTASK_CODE="$(curl -s -o /tmp/${TASK_ID}_pending.json -w "%{http_code}" http://localhost:5555/api/mtask/pending || true)"

echo "[${TASK_ID}] health_http=${HEALTH_CODE}"
echo "[${TASK_ID}] pending_http=${MTASK_CODE}"

echo "[${TASK_ID}] runtime route check inside container..."
docker compose exec -T backend python - <<'PY'
from app.main import app
paths = sorted({getattr(r, "path", "") for r in app.router.routes})
want = [p for p in paths if p.startswith("/api/mtask")]
print("mtask_routes=", want)
PY

if [[ "${HEALTH_CODE}" != "200" ]]; then
  echo "[${TASK_ID}] backend health failed"
  exit 1
fi

if [[ "${MTASK_CODE}" != "200" ]]; then
  echo "[${TASK_ID}] still 404/failed after hard rebuild"
  echo "[${TASK_ID}] openapi probe follows:"
  curl -s http://localhost:5555/openapi.json | python3 - <<'PY'
import sys, json
try:
    d = json.loads(sys.stdin.read())
    paths = sorted((d.get("paths") or {}).keys())
    picks = [p for p in paths if p.startswith("/api/mtask")]
    print("openapi_mtask_paths=", picks)
except Exception as e:
    print("openapi_parse_error=", e)
PY
  exit 1
fi

echo "[${TASK_ID}] mtask endpoint is live"

PROPOSE_PAYLOAD='{"text":"MTASK-0142 smoke proposal for cockpit lane","issued_by":"cockpit-ai","source":"cockpit","session_id":"mtask-0142"}'
PROPOSE_RAW="$(curl -s -X POST http://localhost:5555/api/mtask/propose -H 'Content-Type: application/json' -d "${PROPOSE_PAYLOAD}" || true)"
echo "[${TASK_ID}] propose_raw=${PROPOSE_RAW}"

PROPOSAL_ID="$(echo "${PROPOSE_RAW}" | python3 - <<'PY'
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(d.get("proposal_id", ""))
except Exception:
    print("")
PY
)"

if [[ -z "${PROPOSAL_ID}" ]]; then
  echo "[${TASK_ID}] propose did not return proposal_id"
  exit 1
fi

echo "[${TASK_ID}] success proposal_id=${PROPOSAL_ID}"
exit 0

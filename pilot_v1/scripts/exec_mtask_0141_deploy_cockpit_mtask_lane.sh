#!/usr/bin/env bash
# RULE: No git push from executor. Autopilot handles all git operations.
set -euo pipefail

TASK_ID="MTASK-0141"
REPO="/home/larieladmin/mide-pilot"
CUSTOMIDE="${REPO}/pilot_v1/customide"

echo "[${TASK_ID}] start $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "[${TASK_ID}] objective: deploy cockpit MTASK lane + verify endpoints"

cd "${CUSTOMIDE}"

echo "[${TASK_ID}] rebuilding backend container to load latest routes..."
docker compose up -d --build backend 2>&1 | tail -20

sleep 8

HEALTH_CODE="$(curl -s -o /tmp/${TASK_ID}_health.json -w "%{http_code}" http://localhost:5555/health || true)"
PENDING_CODE="$(curl -s -o /tmp/${TASK_ID}_pending.json -w "%{http_code}" http://localhost:5555/api/mtask/pending || true)"

echo "[${TASK_ID}] health_http=${HEALTH_CODE}"
echo "[${TASK_ID}] pending_http=${PENDING_CODE}"

if [[ "${HEALTH_CODE}" != "200" ]]; then
  echo "[${TASK_ID}] backend health check failed"
  exit 1
fi

if [[ "${PENDING_CODE}" != "200" ]]; then
  echo "[${TASK_ID}] /api/mtask/pending endpoint failed"
  exit 1
fi

PROPOSE_PAYLOAD='{"text":"Smoke test from MTASK-0141 || Validate cockpit mtask lane","issued_by":"cockpit-ai","source":"cockpit","session_id":"mtask-0141"}'
PROPOSE_RAW="$(curl -s -X POST http://localhost:5555/api/mtask/propose -H 'Content-Type: application/json' -d "${PROPOSE_PAYLOAD}" || true)"
echo "[${TASK_ID}] propose_raw=${PROPOSE_RAW}"

PROPOSAL_ID="$(echo "${PROPOSE_RAW}" | python3 -c 'import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(d.get("proposal_id", ""))
except Exception:
    print("")')"

if [[ -z "${PROPOSAL_ID}" ]]; then
  echo "[${TASK_ID}] proposal creation failed"
  exit 1
fi

echo "[${TASK_ID}] proposal_id=${PROPOSAL_ID}"
echo "[${TASK_ID}] deployment complete (proposal created and pending approval)"
exit 0

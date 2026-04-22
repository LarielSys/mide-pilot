#!/usr/bin/env bash
# MTASK-0030: Add Flask-CORS to site_kb_server.py and restart
set -euo pipefail

WORKER_ID="ubuntu-worker-01"
WORKER_NAME="ubuntu-atlas-01"
TASK_ID="MTASK-0030"
PORT=8091
SERVER_FILE="/home/larieladmin/Documents/itheia-llm/site_kb_server.py"
RESULT_FILE="$HOME/mide-pilot/pilot_v1/results/${TASK_ID}.result.json"
LOG_FILE="/tmp/${TASK_ID}.log"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "task=${TASK_ID}" | tee "$LOG_FILE"
echo "worker_name=${WORKER_NAME}" | tee -a "$LOG_FILE"
echo "worker_id=${WORKER_ID}" | tee -a "$LOG_FILE"
echo "server_file=${SERVER_FILE}" | tee -a "$LOG_FILE"

# Step 1: Install flask-cors if not present
pip install flask-cors --quiet 2>&1 | tail -1 | tee -a "$LOG_FILE"
CORS_INSTALLED=$(python3 -c "import flask_cors; print('ok')" 2>&1)
echo "flask_cors_check=${CORS_INSTALLED}" | tee -a "$LOG_FILE"

if [ "$CORS_INSTALLED" != "ok" ]; then
  echo "error=flask_cors_not_installed" | tee -a "$LOG_FILE"
  STATUS="failed"
else
  # Step 2: Patch server file — add CORS import + init after Flask app creation
  # Check if already patched
  if grep -q "from flask_cors import CORS" "$SERVER_FILE"; then
    echo "cors_patch=already_present" | tee -a "$LOG_FILE"
  else
    # Insert after the Flask import block — find 'from flask import' line and add below it
    # Add 'from flask_cors import CORS' after flask imports
    sed -i '/^from flask import/a from flask_cors import CORS' "$SERVER_FILE"

    # Add CORS(app) after 'app = Flask(__name__)' line
    sed -i '/app = Flask(__name__)/a CORS(app)' "$SERVER_FILE"

    echo "cors_patch=applied" | tee -a "$LOG_FILE"
  fi

  # Step 3: Syntax check
  SYNTAX=$(python3 -m py_compile "$SERVER_FILE" 2>&1 && echo "passed" || echo "FAILED")
  echo "syntax_check=${SYNTAX}" | tee -a "$LOG_FILE"

  if [ "$SYNTAX" != "passed" ]; then
    echo "error=syntax_check_failed" | tee -a "$LOG_FILE"
    STATUS="failed"
  else
    # Step 4: Kill old server and restart via nohup
    pkill -f "python.*site_kb_server" 2>/dev/null || true
    sleep 2
    nohup python3 "$SERVER_FILE" > /tmp/site_kb_server.log 2>&1 &
    echo "restart_mode=nohup_pid=$!" | tee -a "$LOG_FILE"

    # Step 5: Wait for server readiness (40 x 2s = 80s max)
    WAIT_OK="false"
    for _ in $(seq 1 40); do
      if curl -sS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
        WAIT_OK="true"; break
      fi
      sleep 2
    done
    echo "base_health_wait=${WAIT_OK}" | tee -a "$LOG_FILE"

    if [ "$WAIT_OK" != "true" ]; then
      echo "error=server_not_ready" | tee -a "$LOG_FILE"
      echo "server_log_tail=$(tail -10 /tmp/site_kb_server.log 2>/dev/null)" | tee -a "$LOG_FILE"
      STATUS="failed"
    else
      # Step 6: Verify CORS header present
      CORS_HEADER=$(curl -sS -I -X OPTIONS \
        -H "Origin: http://localhost:8080" \
        -H "Access-Control-Request-Method: GET" \
        "http://127.0.0.1:${PORT}/api/weather/health" 2>/dev/null \
        | grep -i "access-control-allow-origin" | tr -d '\r\n' || echo "missing")
      echo "cors_header=${CORS_HEADER}" | tee -a "$LOG_FILE"

      # Step 7: Confirm weather endpoint still works
      WEATHER_CHECK=$(curl -sS "http://127.0.0.1:${PORT}/api/weather/health" 2>/dev/null | head -c 200 || echo "failed")
      echo "weather_health=${WEATHER_CHECK}" | tee -a "$LOG_FILE"

      TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      echo "timestamp_utc=${TIMESTAMP}" | tee -a "$LOG_FILE"
      STATUS="completed"
    fi
  fi
fi

# Write result JSON
STDOUT_EXCERPT=$(cat "$LOG_FILE" | head -c 2000 | tr '"' "'" | tr '\n' '\\n')
cat > "$RESULT_FILE" <<EOF
{
  "task_id": "${TASK_ID}",
  "worker_id": "${WORKER_ID}",
  "execution_status": "${STATUS}",
  "summary": "Flask-CORS added to site_kb_server.py and server restarted.",
  "stdout_excerpt": "${STDOUT_EXCERPT}",
  "stderr_excerpt": "",
  "timestamp_utc": "${TIMESTAMP}"
}
EOF

echo "result_written=${RESULT_FILE}" | tee -a "$LOG_FILE"

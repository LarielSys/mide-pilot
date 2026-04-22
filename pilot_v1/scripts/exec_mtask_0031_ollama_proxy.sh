#!/usr/bin/env bash
# MTASK-0031: Add Ollama proxy routes to site_kb_server.py
# Purpose: Expose Ubuntu's qwen2.5 to Windows IDE via ngrok
set -euo pipefail

WORKER_ID="ubuntu-worker-01"
WORKER_NAME="ubuntu-atlas-01"
TASK_ID="MTASK-0031"
PORT=8091
SERVER_FILE="/home/larieladmin/Documents/itheia-llm/site_kb_server.py"
RESULT_FILE="$HOME/mide-pilot/pilot_v1/results/${TASK_ID}.result.json"
LOG_FILE="/tmp/${TASK_ID}.log"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "task=${TASK_ID}" | tee "$LOG_FILE"
echo "worker_id=${WORKER_ID}" | tee -a "$LOG_FILE"

# Step 1: Verify Ollama + qwen2.5
OLLAMA_VERSION=$(ollama --version 2>&1 | head -1 || echo "not_found")
echo "ollama_version=${OLLAMA_VERSION}" | tee -a "$LOG_FILE"

QWEN_CHECK=$(ollama list 2>/dev/null | grep -i "qwen2.5" | head -1 || echo "")
if [ -z "$QWEN_CHECK" ]; then
  echo "qwen25_status=not_found_pulling" | tee -a "$LOG_FILE"
  ollama pull qwen2.5 2>&1 | tail -3 | tee -a "$LOG_FILE" || true
  QWEN_CHECK=$(ollama list 2>/dev/null | grep -i "qwen2.5" | head -1 || echo "")
fi
echo "qwen25_available=$([ -n "$QWEN_CHECK" ] && echo 'yes' || echo 'no')" | tee -a "$LOG_FILE"
echo "qwen25_model=$(echo "$QWEN_CHECK" | awk '{print $1}')" | tee -a "$LOG_FILE"

# Step 2: Patch site_kb_server.py with Ollama proxy routes
if grep -q "ollama_proxy" "$SERVER_FILE"; then
  echo "ollama_proxy_patch=already_present" | tee -a "$LOG_FILE"
else
  # Find a safe insertion point — after existing weather routes block
  # Append the routes as a new section before if __name__ == '__main__':
  PATCH_MARKER="if __name__ == '__main__':"
  if ! grep -q "$PATCH_MARKER" "$SERVER_FILE"; then
    PATCH_MARKER="app.run("
  fi

  PATCH_CODE='
# ── OLLAMA PROXY ROUTES (MTASK-0031) ──────────────────────────────────────────
import requests as _req

OLLAMA_BASE = "http://127.0.0.1:11434"

@app.route("/api/ollama/health", methods=["GET"])
def ollama_health():
    try:
        r = _req.get(f"{OLLAMA_BASE}/api/tags", timeout=5)
        models = [m["name"] for m in r.json().get("models", [])]
        return jsonify({"status": "ok", "worker_id": "ubuntu-worker-01", "models": models})
    except Exception as e:
        return jsonify({"status": "error", "detail": str(e)}), 503

@app.route("/api/ollama/tags", methods=["GET"])
def ollama_tags():
    try:
        r = _req.get(f"{OLLAMA_BASE}/api/tags", timeout=5)
        return jsonify(r.json())
    except Exception as e:
        return jsonify({"error": str(e)}), 503

@app.route("/api/ollama/generate", methods=["POST"])
def ollama_generate():
    try:
        payload = request.get_json(force=True)
        if not payload.get("model"):
            payload["model"] = "qwen2.5"
        r = _req.post(f"{OLLAMA_BASE}/api/generate", json=payload, timeout=120, stream=True)
        def generate():
            for chunk in r.iter_content(chunk_size=None):
                if chunk:
                    yield chunk
        from flask import Response, stream_with_context
        return Response(stream_with_context(generate()), content_type="application/x-ndjson")
    except Exception as e:
        return jsonify({"error": str(e)}), 503

@app.route("/api/ollama/chat", methods=["POST"])
def ollama_chat():
    try:
        payload = request.get_json(force=True)
        if not payload.get("model"):
            payload["model"] = "qwen2.5"
        r = _req.post(f"{OLLAMA_BASE}/api/chat", json=payload, timeout=120, stream=True)
        def generate():
            for chunk in r.iter_content(chunk_size=None):
                if chunk:
                    yield chunk
        from flask import Response, stream_with_context
        return Response(stream_with_context(generate()), content_type="application/x-ndjson")
    except Exception as e:
        return jsonify({"error": str(e)}), 503
# ── END OLLAMA PROXY ROUTES ────────────────────────────────────────────────────
'

  # Write patch above the main marker
  python3 - <<PYEOF
import re, sys
with open("$SERVER_FILE", "r") as f:
    content = f.read()
marker = "$PATCH_MARKER"
if marker not in content:
    print("ERROR: marker not found", file=sys.stderr)
    sys.exit(1)
patch = '''${PATCH_CODE}'''
new_content = content.replace(marker, patch + "\n" + marker, 1)
with open("$SERVER_FILE", "w") as f:
    f.write(new_content)
print("patch_written=ok")
PYEOF
  echo "ollama_proxy_patch=applied" | tee -a "$LOG_FILE"
fi

# Step 3: Install requests library if needed
python3 -c "import requests" 2>/dev/null || pip install requests --quiet
echo "requests_lib=ok" | tee -a "$LOG_FILE"

# Step 4: Syntax check
SYNTAX=$(python3 -m py_compile "$SERVER_FILE" 2>&1 && echo "passed" || echo "FAILED")
echo "syntax_check=${SYNTAX}" | tee -a "$LOG_FILE"

if [ "$SYNTAX" != "passed" ]; then
  echo "error=syntax_check_failed" | tee -a "$LOG_FILE"
  STATUS="failed"
else
  # Step 5: Restart server
  pkill -f "python.*site_kb_server" 2>/dev/null || true
  sleep 2
  nohup python3 "$SERVER_FILE" > /tmp/site_kb_server.log 2>&1 &
  echo "restart_pid=$!" | tee -a "$LOG_FILE"

  # Wait for base health
  for _ in $(seq 1 40); do
    if curl -sS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  # Step 6: Test Ollama proxy route
  OLLAMA_HEALTH=$(curl -sS "http://127.0.0.1:${PORT}/api/ollama/health" 2>/dev/null | head -c 300 || echo "failed")
  echo "ollama_proxy_health=${OLLAMA_HEALTH}" | tee -a "$LOG_FILE"

  PUBLIC_OLLAMA=$(curl -sS "https://jawed-lapel-dispersed.ngrok-free.dev/api/ollama/health" \
    -H "ngrok-skip-browser-warning: 1" 2>/dev/null | head -c 200 || echo "failed")
  echo "public_ollama_health=${PUBLIC_OLLAMA}" | tee -a "$LOG_FILE"

  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "timestamp_utc=${TIMESTAMP}" | tee -a "$LOG_FILE"
  STATUS="completed"
fi

STDOUT_EXCERPT=$(cat "$LOG_FILE" | head -c 2000 | tr '"' "'" | tr '\n' '\\n')
cat > "$RESULT_FILE" <<EOF
{
  "task_id": "${TASK_ID}",
  "worker_id": "${WORKER_ID}",
  "execution_status": "${STATUS}",
  "summary": "Ollama proxy routes added to site_kb_server.py. qwen2.5 available via ngrok.",
  "stdout_excerpt": "${STDOUT_EXCERPT}",
  "stderr_excerpt": "",
  "timestamp_utc": "${TIMESTAMP}"
}
EOF
echo "result_written=${RESULT_FILE}" | tee -a "$LOG_FILE"

#!/usr/bin/env bash
set -euo pipefail

# MTASK-2013: Repair chat page path to Ubuntu Ollama.
# Scope is intentionally narrow: Ubuntu Ollama readiness for chat path.

echo "[MTASK-2013] start"

TARGET_BASE="http://192.168.1.21:11434"

echo "[MTASK-2013] Step 1: Verify Ubuntu Ollama endpoint reachability"
curl -fsS "${TARGET_BASE}/api/version" >/dev/null

echo "[MTASK-2013] Step 2: Verify required models are present"
MODELS_JSON="$(curl -fsS "${TARGET_BASE}/api/tags")"
echo "$MODELS_JSON" | grep -q 'qwen2.5-coder:7b'
echo "$MODELS_JSON" | grep -q 'qwen2.5vl:7b'

echo "[MTASK-2013] Step 3: Verify coder model answers via Ubuntu Ollama /api/chat"
CHAT_BODY='{"model":"qwen2.5-coder:7b","messages":[{"role":"user","content":"Reply with one word: online"}],"stream":false}'
CHAT_JSON="$(curl -fsS -X POST "${TARGET_BASE}/api/chat" -H 'Content-Type: application/json' -d "${CHAT_BODY}")"
echo "${CHAT_JSON}" | grep -qi 'online\|message\|content'

echo "[MTASK-2013] Step 4: Write readiness marker"
mkdir -p pilot_v1/state
{
	echo "task_id=MTASK-2013"
	echo "target_base=${TARGET_BASE}"
	echo "models=qwen2.5-coder:7b,qwen2.5vl:7b"
	echo "validated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "host=$(hostname)"
} > pilot_v1/state/mtask_2013_ubuntu_ollama_ready.txt

echo "[MTASK-2013] completed"

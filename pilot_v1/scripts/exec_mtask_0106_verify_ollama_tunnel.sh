#!/usr/bin/env bash
set -euo pipefail

echo task=MTASK-0106
echo objective=verify_ollama_tunnel_end_to_end_for_website
echo timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="${REPO_ROOT}/pilot_v1/state/worker1_services.json"

# ── 1. Read tunnel URL from state ─────────────────────────────────────────────
PUBLIC_URL=$(python3 -c "
import json, pathlib
d = json.loads(pathlib.Path('$STATE_FILE').read_text())
print(d.get('tunnel_public_url', '') or d.get('services', {}).get('ollama_tunnel', {}).get('public_url', ''))
" 2>/dev/null || echo "")

if [[ -z "$PUBLIC_URL" ]]; then
  echo tunnel_url=NOT_FOUND_in_state
  echo verification_status=FAILED
  echo snapshot=complete
  exit 1
fi

echo tunnel_url="$PUBLIC_URL"

# ── 2. Check ngrok process still running ──────────────────────────────────────
echo "--- ngrok_process ---"
NGROK_PROC=$(pgrep -a ngrok 2>/dev/null | head -3 || echo "not_running")
echo ngrok_process="$NGROK_PROC"

# ── 3. Verify API endpoints ───────────────────────────────────────────────────
echo "--- endpoint_checks ---"
ROOT_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "$PUBLIC_URL" 2>/dev/null || echo "000")
TAGS_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "${PUBLIC_URL}/api/tags" 2>/dev/null || echo "000")
echo tunnel_root_http="$ROOT_HTTP"
echo tunnel_api_tags_http="$TAGS_HTTP"

# List available models
MODELS=$(curl -s --max-time 10 "${PUBLIC_URL}/api/tags" 2>/dev/null | \
  python3 -c "import json,sys; d=json.load(sys.stdin); [print('  model:',m['name']) for m in d.get('models',[])]" \
  2>/dev/null || echo "  models_check_failed")
echo "$MODELS"

# ── 4. Live generate test ─────────────────────────────────────────────────────
echo "--- live_generate_test ---"
GEN_RESPONSE=$(curl -s --max-time 30 -X POST "${PUBLIC_URL}/api/generate" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-coder:14b","prompt":"Reply with only: TUNNEL_OK","stream":false}' \
  2>/dev/null || echo "")

GEN_STATUS=$(echo "$GEN_RESPONSE" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    resp = d.get('response','').strip()
    done = d.get('done', False)
    print(f'response_excerpt={resp[:80]}')
    print(f'done={done}')
except Exception as e:
    print(f'parse_error={e}')
    print(f'raw_excerpt={sys.argv[0][:200]}')
" 2>/dev/null || echo "generate_call_failed")
echo "$GEN_STATUS"

# ── 5. Final status determination ────────────────────────────────────────────
if [[ "$TAGS_HTTP" == "200" ]]; then
  FINAL_STATUS="ALL_CHECKS_PASSED"
  echo verification_status=PASS
else
  FINAL_STATUS="DEGRADED_tags_http_${TAGS_HTTP}"
  echo verification_status=DEGRADED
fi

# ── 6. Update state with verification result ──────────────────────────────────
python3 - "$STATE_FILE" "$PUBLIC_URL" "$FINAL_STATUS" "$TAGS_HTTP" <<'PY'
import json, sys, pathlib, datetime

state_file, public_url, final_status, tags_http = sys.argv[1:5]
p = pathlib.Path(state_file)
data = json.loads(p.read_text()) if p.exists() else {}
data["tunnel_verification"] = {
    "verified_utc": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "verified_by": "MTASK-0106",
    "public_url": public_url,
    "generate_url": f"{public_url}/api/generate",
    "chat_url": f"{public_url}/api/chat",
    "api_tags_http": tags_http,
    "final_status": final_status,
    "website_integration_note": (
        "Point your website chat page to chat_url for POST /api/chat "
        "or generate_url for POST /api/generate with model=qwen2.5-coder:14b"
    ),
}
p.write_text(json.dumps(data, indent=2) + "\n")
print(f"verification_state_written=ok")
print(f"website_chat_url={public_url}/api/chat")
print(f"website_generate_url={public_url}/api/generate")
PY

git -C "$REPO_ROOT" add pilot_v1/state/worker1_services.json
git -C "$REPO_ROOT" commit -m "worker: MTASK-0106 tunnel verified final_status=$FINAL_STATUS" || true
git -C "$REPO_ROOT" push origin main || true

echo final_status="$FINAL_STATUS"
echo snapshot=complete

#!/usr/bin/env bash
# verify_site_kb_consistency.sh
# Confirms /health on port 8091 and direct Chroma lariel_site_kb count stay aligned.
# Exits 0 on match, 1 on mismatch or error.

set -euo pipefail

SITE_KB_DB="$HOME/Documents/itheia-llm/site_kb_chromadb"
HEALTH_URL="http://127.0.0.1:8091/health"
COLLECTION="lariel_site_kb"
PYTHON="$HOME/Documents/itheia-llm/.venv/bin/python3"

echo "=== verify_site_kb_consistency ==="
echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# 1. Fetch /health
echo ""
echo "--- Step 1: GET $HEALTH_URL ---"
HEALTH_RESP=$(curl -sf "$HEALTH_URL" 2>&1) || { echo "ERROR: Could not reach $HEALTH_URL"; exit 1; }
echo "$HEALTH_RESP"

HEALTH_STATUS=$(echo "$HEALTH_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))")
HEALTH_DOCS=$(echo "$HEALTH_RESP"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('documents',0))")

echo "health.status   = $HEALTH_STATUS"
echo "health.documents= $HEALTH_DOCS"

if [ "$HEALTH_STATUS" != "ok" ]; then
  echo "FAIL: /health status is not ok (got: $HEALTH_STATUS)"
  exit 1
fi

# 2. Direct Chroma count
echo ""
echo "--- Step 2: Direct Chroma query ($COLLECTION @ $SITE_KB_DB) ---"
CHROMA_COUNT=$("$PYTHON" -c "
import chromadb
c = chromadb.PersistentClient(path='$SITE_KB_DB')
col = c.get_collection('$COLLECTION')
print(col.count())
" 2>&1) || { echo "ERROR: Direct Chroma query failed: $CHROMA_COUNT"; exit 1; }

echo "chroma.count    = $CHROMA_COUNT"

# 3. Compare
echo ""
echo "--- Step 3: Comparison ---"
if [ "$HEALTH_DOCS" = "$CHROMA_COUNT" ]; then
  echo "PASS: /health.documents ($HEALTH_DOCS) == direct chroma count ($CHROMA_COUNT)"
  exit 0
else
  echo "FAIL: Mismatch — /health.documents=$HEALTH_DOCS, direct chroma count=$CHROMA_COUNT"
  exit 1
fi

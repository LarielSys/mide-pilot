#!/usr/bin/env bash
set -euo pipefail

WORKER_NAME="${WORKER_NAME:-ubuntu-atlas-01}"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"
SITE_URL="https://larielsystems.com/"
CLONE_ROOT="${HOME}/mide-pilot/clone"
MIRROR_ROOT="${CLONE_ROOT}/larielsystems"
DOMAIN_ROOT="${MIRROR_ROOT}/larielsystems.com"
PORT="8787"

mkdir -p "${CLONE_ROOT}"
rm -rf "${MIRROR_ROOT}"
mkdir -p "${MIRROR_ROOT}"

echo "task=TASK-0022"
echo "worker_name=${WORKER_NAME}"
echo "worker_id=${WORKER_ID}"
echo "clone_root=${CLONE_ROOT}"
echo "source=${SITE_URL}"

wget \
  --mirror \
  --convert-links \
  --adjust-extension \
  --page-requisites \
  --no-parent \
  --domains larielsystems.com \
  "${SITE_URL}" \
  -P "${MIRROR_ROOT}" >/dev/null 2>&1

if [[ ! -d "${DOMAIN_ROOT}" ]]; then
  echo "mirror_failed=domain_root_missing"
  exit 1
fi

chat_file="$(find "${DOMAIN_ROOT}" -type f \( -name "chat.html" -o -path "*/chat/index.html" \) | head -n 1 || true)"
if [[ -z "${chat_file}" ]]; then
  echo "chat_dependency_check=failed"
  echo "reason=chat_file_not_found_in_mirror"
  exit 1
fi

echo "chat_file=${chat_file}"

python3 - "${chat_file}" <<'PY'
import os
import re
import sys

chat_file = sys.argv[1]
base_dir = os.path.dirname(chat_file)
text = open(chat_file, "r", encoding="utf-8", errors="replace").read()

refs = re.findall(r'(?:src|href)=["\']([^"\']+)["\']', text, flags=re.IGNORECASE)
local_refs = []
for ref in refs:
    if ref.startswith(("http://", "https://", "#", "mailto:", "javascript:")):
        continue
    clean = ref.split("?", 1)[0].split("#", 1)[0].strip()
    if not clean:
        continue
    local_refs.append(clean)

missing = []
for ref in local_refs:
    candidate = os.path.normpath(os.path.join(base_dir, ref))
    if not os.path.exists(candidate):
        missing.append(ref)

print(f"chat_local_ref_count={len(local_refs)}")
print(f"chat_missing_ref_count={len(missing)}")
if missing:
    print("chat_missing_refs=" + ",".join(missing[:20]))
    sys.exit(1)
else:
    print("chat_dependency_check=passed")
PY

HTTP_LOG="$(mktemp)"
python3 -m http.server "${PORT}" --directory "${DOMAIN_ROOT}" >/dev/null 2>&1 &
SERVER_PID=$!

cleanup() {
  if ps -p "${SERVER_PID}" >/dev/null 2>&1; then
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
  fi
  rm -f "${HTTP_LOG}"
}
trap cleanup EXIT

sleep 2

http_code="$(curl -sS -o "${HTTP_LOG}" -w "%{http_code}" "http://127.0.0.1:${PORT}/")"

echo "localhost_url=http://127.0.0.1:${PORT}/"
echo "localhost_http_code=${http_code}"

auto_ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "timestamp_utc=${auto_ts}"

if [[ "${http_code}" != "200" ]]; then
  echo "localhost_probe=failed"
  exit 1
fi

echo "localhost_probe=passed"

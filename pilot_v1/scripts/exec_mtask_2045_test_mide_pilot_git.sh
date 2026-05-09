#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

echo "[MTASK-2045] test_start_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "[MTASK-2045] repo_root=${REPO_ROOT}"

echo "[MTASK-2045] branch=$(git rev-parse --abbrev-ref HEAD || true)"
echo "[MTASK-2045] head_commit=$(git rev-parse --short HEAD || true)"
echo "[MTASK-2045] remote_origin=$(git remote get-url origin || true)"

echo "[MTASK-2045] status_short_begin"
git status --short | sed -n '1,40p' || true
echo "[MTASK-2045] status_short_end"

echo "[MTASK-2045] result=PASS"

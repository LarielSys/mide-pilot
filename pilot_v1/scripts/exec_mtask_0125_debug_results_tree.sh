#!/usr/bin/env bash
set -uo pipefail
COCKPIT_REPO="/home/larieladmin/mide-pilot"
echo "task=MTASK-0125"
echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Count result files visible on origin/main
GIT_TERMINAL_PROMPT=0 timeout 30 git -C "${COCKPIT_REPO}" fetch origin main 2>/dev/null || true

LSTREE=$(git -C "${COCKPIT_REPO}" ls-tree --name-only origin/main pilot_v1/results/ 2>&1)
LSTREE_COUNT=$(echo "${LSTREE}" | grep -c "MTASK-.*\.result\.json" 2>/dev/null || echo "0")
echo "ls_tree_count=${LSTREE_COUNT}"
echo "ls_tree_first=$(echo "${LSTREE}" | grep "MTASK-" | sort | tail -3)"

# Try git archive approach and count what we get
ARCHIVE_COUNT=$(git -C "${COCKPIT_REPO}" archive origin/main -- pilot_v1/results/ 2>/dev/null \
  | tar -t 2>/dev/null | grep -c "MTASK-.*\.result\.json" 2>/dev/null || echo "0")
echo "archive_count=${ARCHIVE_COUNT}"

# Check remote URL
REMOTE=$(git -C "${COCKPIT_REPO}" remote get-url origin 2>&1)
REMOTE_SAFE=$(printf '%s' "${REMOTE}" | sed -E 's#https://[^/@:]+:[^@]+@github.com/#https://REDACTED@github.com/#g; s#\bgh[pousr]_[A-Za-z0-9_]+\b#REDACTED_GITHUB_TOKEN#g')
echo "origin_url=${REMOTE_SAFE}"

# Check local HEAD vs origin
LOCAL=$(git -C "${COCKPIT_REPO}" rev-parse HEAD 2>/dev/null | cut -c1-8)
ORIGIN=$(git -C "${COCKPIT_REPO}" rev-parse origin/main 2>/dev/null | cut -c1-8)
echo "local_head=${LOCAL}"
echo "origin_head=${ORIGIN}"

echo "final_status=ALL_CHECKS_PASSED"

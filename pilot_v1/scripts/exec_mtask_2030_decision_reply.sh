#!/usr/bin/env bash
set -euo pipefail

echo "task=MTASK-2030"
echo "decision=OPTION_A"
echo "context=MTASK-2029 consult resolution"
echo "summary=Proceed by creating the missing executor script for MTASK-2028 so retries stop failing."
echo "why=MTASK-2028 and retries fail on missing pilot_v1/scripts/exec_mtask_2028_confirm_gate.sh; this is root cause."
echo "required_actions=1) create exec_mtask_2028_confirm_gate.sh 2) commit script 3) let next retry run and write result evidence"
echo "guardrail=do_not_delete_result_files; use new task ids for new work"
echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

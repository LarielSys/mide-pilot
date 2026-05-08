#!/usr/bin/env bash
set -euo pipefail

mkdir -p pilot_v1/state
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOSTNAME_VAL="$(hostname)"

{
  echo "task_id=MTASK-2014"
  echo "picked_by=${HOSTNAME_VAL}"
  echo "picked_at=${TS}"
} > pilot_v1/state/mtask_2014_pickup_probe.txt

echo "MTASK-2014 pickup probe completed at ${TS} on ${HOSTNAME_VAL}"

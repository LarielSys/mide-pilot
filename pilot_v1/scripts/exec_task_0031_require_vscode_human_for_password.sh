#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKER_ID="${WORKER_ID:-ubuntu-worker-01}"

TARGETS=(
  "pilot_v1/scripts/exec_mtask_0031_ollama_proxy.sh"
  "pilot_v1/scripts/exec_mtask_0032_ssh_bootstrap.sh"
  "pilot_v1/scripts/exec_mtask_0033_codeserver_install.sh"
  "pilot_v1/scripts/exec_mtask_0034_codeserver_ngrok_verify.sh"
)

echo "task=TASK-0031"
echo "worker_id=${WORKER_ID}"
echo "policy=when_password_needed_must_request_vscode_human_interaction"

cd "${REPO_ROOT}"
git fetch origin
git pull --ff-only origin main

python3 - "$REPO_ROOT" <<'PY'
from pathlib import Path
import re
import sys

repo_root = Path(sys.argv[1])
targets = [
    Path("pilot_v1/scripts/exec_mtask_0031_ollama_proxy.sh"),
    Path("pilot_v1/scripts/exec_mtask_0032_ssh_bootstrap.sh"),
    Path("pilot_v1/scripts/exec_mtask_0033_codeserver_install.sh"),
    Path("pilot_v1/scripts/exec_mtask_0034_codeserver_ngrok_verify.sh"),
]

helper_block = """
# VS human-interaction gate for password-protected commands.
require_vscode_human_interaction() {
  local reason="${1:-password required}"
  echo "human_interaction_required=true"
  echo "human_interaction_channel=vscode"
  echo "human_interaction_reason=${reason}"
  echo "human_interaction_instruction=Open VS Code terminal and provide required password interactively, then rerun this task."
  exit 42
}

run_sudo_or_request_human() {
  if sudo -n true >/dev/null 2>&1; then
    sudo "$@"
  else
    require_vscode_human_interaction "sudo password required for command: sudo $*"
  fi
}
""".strip("\n")

patched = []
for rel in targets:
    p = repo_root / rel
    if not p.exists():
        continue
    src = p.read_text(encoding="utf-8", errors="replace")

    if "run_sudo_or_request_human()" not in src:
        marker = "set -euo pipefail\n"
        if marker in src:
            src = src.replace(marker, marker + "\n" + helper_block + "\n\n", 1)

    lines = src.splitlines()
    new_lines = []
    changed = False
    for line in lines:
        if line.lstrip().startswith("sudo "):
            indent = line[: len(line) - len(line.lstrip())]
            replaced = indent + line.lstrip().replace("sudo ", "run_sudo_or_request_human ", 1)
            if replaced != line:
                changed = True
            new_lines.append(replaced)
        else:
            new_lines.append(line)

    new_src = "\n".join(new_lines) + "\n"
    if new_src != p.read_text(encoding="utf-8", errors="replace"):
        p.write_text(new_src, encoding="utf-8")
        patched.append(str(rel))
    elif changed:
        patched.append(str(rel))

print("patched_files=" + (",".join(patched) if patched else "none"))
PY

for rel in "${TARGETS[@]}"; do
  abs="${REPO_ROOT}/${rel}"
  if [[ -f "${abs}" ]]; then
    bash -n "${abs}"
  fi
done

git add "${TARGETS[@]}"
git commit -m "worker policy: require VS human interaction when password is needed"
git push origin main

echo "policy_patch_commit=ok"
echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

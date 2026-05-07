"""
Operator Loop — Windows Main IDE background service.

Runs as an asyncio task inside the cockpit FastAPI backend.
Every 60 seconds:
  1. git fetch + merge origin/main
  2. Scan pilot_v1/results/ for unprocessed result files
  3. On completed task: promote next pipeline task to approved_to_execute
  4. On failed task: issue a retry (up to MAX_RETRIES)
  5. Write heartbeat to pilot_v1/state/operator_loop_live.txt and push
"""

import asyncio
import json
import logging
import os
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

logger = logging.getLogger("operator_loop")

POLL_SECONDS = 60
MAX_RETRIES = 2

# ── repo paths ─────────────────────────────────────────────────────────────────
def _repo_root() -> Path:
    # backend/app/operator_loop.py → pilot_v1/customide/backend/app/
    # parents[3] = pilot_v1/customide, parents[4] = pilot_v1, parents[5] = MIDE root
    return Path(__file__).resolve().parents[4]


def _tasks_dir(root: Path) -> Path:
    return root / "pilot_v1" / "tasks"


def _results_dir(root: Path) -> Path:
    return root / "pilot_v1" / "results"


def _scripts_dir(root: Path) -> Path:
    return root / "pilot_v1" / "scripts"


def _state_dir(root: Path) -> Path:
    return root / "pilot_v1" / "state"


def _processed_log(root: Path) -> Path:
    return _state_dir(root) / "operator_loop_processed.json"


def _operator_log(root: Path) -> Path:
    return _state_dir(root) / "operator_loop.log"


# ── helpers ────────────────────────────────────────────────────────────────────
def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _log(root: Path, msg: str) -> None:
    ts = datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
    line = f"[{ts}] {msg}"
    logger.info(msg)
    try:
        with open(_operator_log(root), "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def _run_git(root: Path, args: list[str], timeout: int = 25) -> tuple[int, str, str]:
    env = dict(os.environ)
    env.setdefault("GIT_TERMINAL_PROMPT", "0")
    try:
        proc = subprocess.run(
            ["git", "-C", str(root), *args],
            capture_output=True, text=True, timeout=timeout, check=False, env=env,
        )
        return proc.returncode, (proc.stdout or "").strip(), (proc.stderr or "").strip()
    except Exception as exc:
        return 1, "", str(exc)


def _git_push(root: Path, message: str) -> None:
    _run_git(root, ["add", "pilot_v1/tasks/", "pilot_v1/scripts/", "pilot_v1/state/"])
    rc, diff, _ = _run_git(root, ["diff", "--cached", "--stat"])
    if diff and "file" in diff:
        _run_git(root, ["commit", "-m", message])
        _run_git(root, ["pull", "origin", "main", "--no-rebase", "--quiet"])
        _run_git(root, ["push", "origin", "main"])
        _log(root, f"GIT PUSH: {message}")


# ── processed state ────────────────────────────────────────────────────────────
def _load_processed(root: Path) -> set[str]:
    path = _processed_log(root)
    if path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            return set(data.get("processed", []))
        except Exception:
            pass
    return set()


def _save_processed(root: Path, processed: set[str]) -> None:
    _processed_log(root).write_text(
        json.dumps({"processed": sorted(processed)}, indent=2), encoding="utf-8"
    )


# ── pipeline definition ────────────────────────────────────────────────────────
# Maps completed task base-ID → next task spec.
# script_body=None means executor script already exists on disk.
PIPELINE: dict[str, dict] = {
    "MTASK-0097": {
        "id": "MTASK-0098",
        "objective": "code-server is UP (MTASK-0097). Restart site_kb_server on port 8091.",
        "script": "exec_mtask_0098_restart_site_kb_server.sh",
        "script_body": None,
    },
    "MTASK-0098": {
        "id": "MTASK-0099",
        "objective": "Recovery complete. Run full stack verification.",
        "script": "exec_mtask_0099_full_stack_verify.sh",
        "script_body": None,
    },
    "MTASK-0103": {
        "id": "MTASK-0104",
        "objective": "Services verified. Diagnose Ollama tunnel status.",
        "script": "exec_mtask_0104_diagnose_ollama_tunnel.sh",
        "script_body": None,
    },
    "MTASK-0104": {
        "id": "MTASK-0105",
        "objective": "Diagnosis complete. Set up persistent Ollama ngrok tunnel for website.",
        "script": "exec_mtask_0105_setup_ollama_tunnel.sh",
        "script_body": None,
    },
    "MTASK-0105": {
        "id": "MTASK-0106",
        "objective": "Tunnel established. Verify end-to-end Ollama tunnel for website chat.",
        "script": "exec_mtask_0106_verify_ollama_tunnel.sh",
        "script_body": None,
    },
}


# ── task management ────────────────────────────────────────────────────────────
def _base_id(task_id: str) -> str:
    """Strip all -RETRYn suffixes."""
    import re
    return re.sub(r"(-RETRY\d+)+$", "", task_id)


def _retry_count(tasks_dir: Path, base_id: str) -> int:
    import re
    count = 0
    for f in tasks_dir.glob(f"{base_id}-RETRY*.json"):
        if re.match(rf"^{re.escape(base_id)}-RETRY\d+\.json$", f.name):
            count += 1
    return count


def _next_retry_num(tasks_dir: Path, base_id: str) -> int:
    import re
    nums = []
    for f in tasks_dir.glob(f"{base_id}-RETRY*.json"):
        m = re.match(rf"^{re.escape(base_id)}-RETRY(\d+)\.json$", f.name)
        if m:
            nums.append(int(m.group(1)))
    return max(nums, default=0) + 1


def _issue_retry(root: Path, result: dict) -> None:
    task_id = result.get("task_id", "")
    base = _base_id(task_id)
    tasks_dir = _tasks_dir(root)
    orig_file = tasks_dir / f"{base}.json"

    if not orig_file.exists():
        _log(root, f"RETRY SKIPPED: original task file not found: {orig_file.name}")
        return

    retry_count = _retry_count(tasks_dir, base)
    if retry_count >= MAX_RETRIES:
        _log(root, f"FAILED: max retries ({MAX_RETRIES}) reached for {base} — operator input needed")
        return

    retry_num = _next_retry_num(tasks_dir, base)
    retry_id = f"{base}-RETRY{retry_num}"

    orig = json.loads(orig_file.read_text(encoding="utf-8"))
    orig["task_id"] = retry_id
    orig["timestamp_utc"] = _utc_now()
    orig["objective"] = f"RETRY{retry_num}: " + orig.get("objective", "")
    orig["created_by"] = "windows-main"

    retry_file = tasks_dir / f"{retry_id}.json"
    retry_file.write_text(json.dumps(orig, indent=2), encoding="utf-8")
    _log(root, f"RETRY CREATED: {retry_id} (reason: {result.get('summary', '')})")
    _git_push(root, f"operator-loop: {retry_id} auto-retry")


def _issue_next(root: Path, completed_id: str) -> None:
    base = _base_id(completed_id)
    entry = PIPELINE.get(base)
    if not entry:
        _log(root, f"NO PIPELINE ENTRY for {completed_id} — operator input needed")
        return

    tasks_dir = _tasks_dir(root)
    scripts_dir = _scripts_dir(root)
    task_file = tasks_dir / f"{entry['id']}.json"
    script_file = scripts_dir / entry["script"]

    # If task file already exists, promote pending → approved_to_execute
    if task_file.exists():
        existing = json.loads(task_file.read_text(encoding="utf-8"))
        if existing.get("status") == "pending":
            existing["status"] = "approved_to_execute"
            task_file.write_text(json.dumps(existing, indent=2), encoding="utf-8")
            _log(root, f"NEXT TASK {entry['id']} promoted pending → approved_to_execute")
            _git_push(root, f"operator-loop: {entry['id']} promoted to approved_to_execute")
        else:
            _log(root, f"NEXT TASK {entry['id']} already exists (status={existing.get('status')}), skipping")
        return

    # Write executor script if body provided inline
    if entry.get("script_body"):
        script_file.write_text(entry["script_body"], encoding="utf-8")
        _log(root, f"SCRIPT WRITTEN: {entry['script']}")

    # Write task JSON
    task = {
        "task_id": entry["id"],
        "created_by": "windows-main",
        "worker_name": "ubuntu-atlas-01",
        "assigned_to": "ubuntu-worker-01",
        "required_worker_id": "ubuntu-worker-01",
        "objective": entry["objective"],
        "executor_script": f"pilot_v1/scripts/{entry['script']}",
        "moss_labels": ["moss/customide", "worker/execute"],
        "priority": "normal",
        "risk_level": "low",
        "automation_mode": "auto",
        "admin_override_allowed": False,
        "allowed_paths": ["pilot_v1/results", "pilot_v1/state"],
        "blocked_paths": [],
        "required_validation": [],
        "dependencies": [],
        "timeout_seconds": 180,
        "status": "approved_to_execute",
        "issued_by": "windows-main",
        "timestamp_utc": _utc_now(),
    }
    task_file.write_text(json.dumps(task, indent=2), encoding="utf-8")
    _log(root, f"NEXT TASK ISSUED: {entry['id']}")
    _git_push(root, f"operator-loop: {entry['id']} auto-issued after {completed_id}")


# ── heartbeat ──────────────────────────────────────────────────────────────────
def _write_heartbeat(root: Path) -> None:
    ts = int(time.time())
    hb_file = _state_dir(root) / "operator_loop_live.txt"
    hb_file.write_text(f"operator_loop windows-main {ts}\n", encoding="utf-8")
    _run_git(root, ["add", "pilot_v1/state/operator_loop_live.txt"])
    rc, diff, _ = _run_git(root, ["diff", "--cached", "--stat"])
    if diff and "operator_loop_live" in diff:
        _run_git(root, ["commit", "-m", f"operator: heartbeat windows-main {ts}"])
        _run_git(root, ["push", "origin", "main"])


# ── main loop ──────────────────────────────────────────────────────────────────
async def run_operator_loop() -> None:
    root = _repo_root()
    processed = _load_processed(root)
    _log(root, f"=== OPERATOR LOOP STARTED (cockpit embedded) | poll={POLL_SECONDS}s | repo={root} ===")

    while True:
        try:
            await asyncio.sleep(POLL_SECONDS)

            # 1. Sync from remote
            _run_git(root, ["fetch", "origin"])
            _run_git(root, ["merge", "origin/main", "-X", "theirs", "--no-edit"])

            results_dir = _results_dir(root)
            if not results_dir.exists():
                continue

            # 2. Scan results
            result_files = sorted(results_dir.glob("*.result.json"), key=lambda f: f.name)
            for result_file in result_files:
                rid = result_file.stem.replace(".result", "")
                if rid in processed:
                    continue

                try:
                    result = json.loads(result_file.read_text(encoding="utf-8"))
                except Exception:
                    continue

                status = result.get("execution_status", "")
                _log(root, f"NEW RESULT: {rid} | status={status}")

                if status == "completed":
                    _log(root, "  -> SUCCESS: issuing next task in pipeline")
                    _issue_next(root, rid)
                elif status == "failed":
                    base = _base_id(rid)
                    retries = _retry_count(_tasks_dir(root), base)
                    if retries < MAX_RETRIES:
                        _log(root, f"  -> FAILED: issuing retry ({retries} previous retries)")
                        _issue_retry(root, result)
                    else:
                        _log(root, f"  -> FAILED: max retries reached for {rid} — operator input needed")

                processed.add(rid)
                _save_processed(root, processed)

            # 3. Heartbeat
            _write_heartbeat(root)

        except asyncio.CancelledError:
            _log(root, "=== OPERATOR LOOP STOPPED ===")
            raise
        except Exception as exc:
            _log(root, f"LOOP ERROR: {exc}")
            # Don't crash the loop on transient errors

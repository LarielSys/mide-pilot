#!/usr/bin/env python3
"""
localctl.py  —  MIDE Local Task Control
Replaces git push/pull for task coordination.
All reads/writes are local file I/O — no GitHub required.

Commands:
  push   <task_id> <description> [--executor path] [--priority high|medium|low]
             Write a new task JSON to pilot_v1/tasks/ and log the push event.
  pull   [--quiet]
             Scan pilot_v1/results/ for result files not yet in processed list.
             Log every new result to operator_loop.log and update processed.json.
  status
             Print a summary: pending tasks, unread results, last event.
  watch  [--interval N]
             Daemon mode: run pull every N seconds (default 30).
  log    [--tail N]
             Print the last N lines of operator_loop.log (default 30).

Usage examples:
  python localctl.py push MTASK-0137 "Fix Ollama LAN URL in mide-chat"
  python localctl.py pull
  python localctl.py status
  python localctl.py watch --interval 15
  python localctl.py log --tail 50
"""

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# ─── Paths ────────────────────────────────────────────────────────────────────

REPO_ROOT   = Path(__file__).parent
PILOT       = REPO_ROOT / "pilot_v1"
TASKS_DIR   = PILOT / "tasks"
RESULTS_DIR = PILOT / "results"
STATE_DIR   = PILOT / "state"

LOG_FILE        = STATE_DIR / "operator_loop.log"
PROCESSED_FILE  = STATE_DIR / "operator_loop_processed.json"
EVENTS_LOG      = STATE_DIR / "worker_autopilot_events.log"

WORKER_ID    = "ubuntu-worker-01"
ISSUED_BY    = "windows-main"

# ─── Helpers ──────────────────────────────────────────────────────────────────

def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")

def ts() -> str:
    return datetime.now().strftime("%Y-%m-%dT%H:%M:%S")

def log_event(msg: str, also_events: bool = False):
    """Append a line to operator_loop.log in the canonical format."""
    line = f"[{ts()}] {msg}\n"
    with open(LOG_FILE, "a", encoding="utf-8") as f:
        f.write(line)
    if also_events:
        with open(EVENTS_LOG, "a", encoding="utf-8") as f:
            f.write(line)
    print(line.rstrip())

def write_json(path: Path, data: dict):
    """Write JSON without BOM."""
    path.write_text(json.dumps(data, indent=2), encoding="utf-8")

def load_processed() -> list:
    if not PROCESSED_FILE.exists():
        return []
    try:
        data = json.loads(PROCESSED_FILE.read_text(encoding="utf-8"))
        return data.get("processed", [])
    except Exception:
        return []

def save_processed(processed: list):
    write_json(PROCESSED_FILE, {"processed": processed})

def next_task_id() -> str:
    """Auto-detect next MTASK number from tasks/ directory."""
    nums = []
    for f in TASKS_DIR.glob("MTASK-*.json"):
        stem = f.stem  # e.g. MTASK-0137
        parts = stem.split("-")
        if len(parts) >= 2 and parts[1].isdigit():
            nums.append(int(parts[1]))
    if not nums:
        return "MTASK-0001"
    return f"MTASK-{max(nums)+1:04d}"

# ─── Commands ─────────────────────────────────────────────────────────────────

def cmd_push(args):
    task_id   = args.task_id or next_task_id()
    desc      = args.description
    priority  = args.priority or "high"
    executor  = args.executor or f"pilot_v1/scripts/exec_{task_id.lower().replace('-','_')}.sh"

    task_path = TASKS_DIR / f"{task_id}.json"
    if task_path.exists() and not args.force:
        print(f"ERROR: {task_path.name} already exists. Use --force to overwrite.")
        sys.exit(1)

    task = {
        "task_id":           task_id,
        "issued_by":         ISSUED_BY,
        "issued_at":         now_iso(),
        "priority":          priority,
        "assigned_to":       WORKER_ID,
        "required_worker_id": WORKER_ID,
        "status":            "approved_to_execute",
        "description":       desc,
        "executor_script":   executor,
        "dependencies":      [],
        "notes":             args.notes or "",
    }

    write_json(task_path, task)
    log_event(f"LOCALCTL PUSH: {task_id} | priority={priority} | {desc}", also_events=True)
    print(f"\n  Task file : {task_path.relative_to(REPO_ROOT)}")
    print(f"  Status    : approved_to_execute")
    print(f"  Executor  : {executor}")
    print(f"\n  [Push complete — no git required]\n")


def cmd_pull(args):
    quiet     = args.quiet
    processed = load_processed()
    processed_set = set(processed)

    new_results = []
    for f in sorted(RESULTS_DIR.glob("*.result.json")):
        stem = f.stem.replace(".result", "")
        if stem not in processed_set:
            new_results.append((stem, f))

    if not new_results:
        if not quiet:
            print(f"[{ts()}] pull: no new results (processed={len(processed)})")
        return 0

    for task_id, result_file in new_results:
        try:
            data = json.loads(result_file.read_text(encoding="utf-8"))
            status = data.get("execution_status", "unknown")
        except Exception:
            status = "unreadable"

        log_event(f"NEW RESULT: {task_id} | status={status}", also_events=True)

        if status == "completed":
            log_event(f"  -> SUCCESS: result pulled for {task_id}")
        elif status == "failed":
            log_event(f"  -> FAILED: {task_id} — check result file for errors")
        else:
            log_event(f"  -> STATUS={status}: {task_id}")

        processed.append(task_id)

    save_processed(processed)
    print(f"\n  Pulled {len(new_results)} new result(s). Processed total: {len(processed)}\n")
    return len(new_results)


def cmd_status(args):
    processed = set(load_processed())

    all_tasks = sorted(TASKS_DIR.glob("*.json"))
    pending = []
    for f in all_tasks:
        stem = f.stem
        result_path = RESULTS_DIR / f"{stem}.result.json"
        if not result_path.exists():
            try:
                data = json.loads(f.read_text(encoding="utf-8"))
                if data.get("status") == "approved_to_execute":
                    pending.append(stem)
            except Exception:
                pass

    unread_results = []
    for f in sorted(RESULTS_DIR.glob("*.result.json")):
        stem = f.stem.replace(".result", "")
        if stem not in processed:
            unread_results.append(stem)

    # last 5 log lines
    last_lines = []
    if LOG_FILE.exists():
        lines = LOG_FILE.read_text(encoding="utf-8").splitlines()
        last_lines = lines[-5:] if len(lines) >= 5 else lines

    print(f"\n  ═══ LOCALCTL STATUS ═══════════════════════════════")
    print(f"  Pending tasks (no result yet): {len(pending)}")
    for t in pending[-10:]:
        print(f"    - {t}")
    print(f"  Unread results (not pulled)  : {len(unread_results)}")
    for r in unread_results[-10:]:
        print(f"    - {r}")
    print(f"  Processed total              : {len(processed)}")
    print(f"\n  — Last log entries —")
    for ln in last_lines:
        print(f"  {ln}")
    print()


def cmd_watch(args):
    interval = args.interval or 30
    print(f"[{ts()}] LOCALCTL WATCH started — polling every {interval}s  (Ctrl+C to stop)\n")
    log_event(f"LOCALCTL WATCH started | interval={interval}s")
    try:
        while True:
            pulled = cmd_pull(argparse.Namespace(quiet=True))
            if pulled:
                print(f"[{ts()}] watch: pulled {pulled} result(s)")
            time.sleep(interval)
    except KeyboardInterrupt:
        log_event("LOCALCTL WATCH stopped by user")
        print(f"\n[{ts()}] Watch stopped.\n")


def cmd_log(args):
    n = args.tail or 30
    if not LOG_FILE.exists():
        print("No log file yet.")
        return
    lines = LOG_FILE.read_text(encoding="utf-8").splitlines()
    for ln in lines[-n:]:
        print(ln)


# ─── Entry point ──────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        prog="localctl",
        description="MIDE Local Task Control — git-free push/pull for autopilot tasks"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # push
    p_push = sub.add_parser("push", help="Write a new task JSON locally")
    p_push.add_argument("task_id", nargs="?", default=None,
                        help="e.g. MTASK-0137 (auto-detected if omitted)")
    p_push.add_argument("description", help="Human-readable task objective")
    p_push.add_argument("--executor", default=None, help="executor_script path on Ubuntu")
    p_push.add_argument("--priority", choices=["high","medium","low"], default="high")
    p_push.add_argument("--notes", default="", help="Optional notes field")
    p_push.add_argument("--force", action="store_true", help="Overwrite existing task file")

    # pull
    p_pull = sub.add_parser("pull", help="Scan results/ and log new completions")
    p_pull.add_argument("--quiet", action="store_true")

    # status
    sub.add_parser("status", help="Show pending tasks and unread results")

    # watch
    p_watch = sub.add_parser("watch", help="Daemon mode — poll for results continuously")
    p_watch.add_argument("--interval", type=int, default=30, help="Poll interval in seconds")

    # log
    p_log = sub.add_parser("log", help="Print last N lines of operator_loop.log")
    p_log.add_argument("--tail", type=int, default=30)

    args = parser.parse_args()

    dispatch = {
        "push":   cmd_push,
        "pull":   cmd_pull,
        "status": cmd_status,
        "watch":  cmd_watch,
        "log":    cmd_log,
    }
    dispatch[args.command](args)


if __name__ == "__main__":
    main()

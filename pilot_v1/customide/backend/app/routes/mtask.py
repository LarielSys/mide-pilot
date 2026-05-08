import json
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import APIRouter
from pydantic import BaseModel, Field


router = APIRouter(prefix="/api/mtask", tags=["mtask"])

WORKER_ID = "ubuntu-worker-01"
MAX_TASKS_PER_PROPOSAL = 3
_NL_MTASK_CREATE_RE = re.compile(
    r"\b(create|make|write|generate|issue|add|submit|send)\s+(a\s+)?(new\s+)?mtask\b",
    re.IGNORECASE,
)


class ProposeRequest(BaseModel):
    text: str = Field(min_length=1, max_length=4000)
    issued_by: str = Field(default="cockpit-ai", min_length=1, max_length=120)
    source: str = Field(default="cockpit", min_length=1, max_length=80)
    session_id: str = Field(default="", max_length=160)


class ApproveRequest(BaseModel):
    proposal_id: str = Field(min_length=1, max_length=120)
    approved_by: str = Field(default="operator", min_length=1, max_length=120)


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _tasks_dir() -> Path:
    return _repo_root() / "pilot_v1" / "tasks"


def _queue_root() -> Path:
    return _repo_root() / "pilot_v1" / "state" / "local_queue"


def _proposals_dir() -> Path:
    return _queue_root() / "proposals"


def _rollback_dir() -> Path:
    return _queue_root() / "rollback"


def _events_file() -> Path:
    return _queue_root() / "events.jsonl"


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _ensure_dirs() -> None:
    _tasks_dir().mkdir(parents=True, exist_ok=True)
    _proposals_dir().mkdir(parents=True, exist_ok=True)
    _rollback_dir().mkdir(parents=True, exist_ok=True)
    _queue_root().mkdir(parents=True, exist_ok=True)


def _append_event(event: dict[str, Any]) -> None:
    _ensure_dirs()
    with _events_file().open("a", encoding="utf-8") as f:
        f.write(json.dumps(event, ensure_ascii=True) + "\n")


def _split_objectives(raw_text: str) -> list[str]:
    text = (raw_text or "").strip()
    if not text:
        return []

    lines: list[str] = []
    for line in text.splitlines():
        item = line.strip()
        if not item:
            continue
        item = re.sub(r"^[-*]\s+", "", item)
        item = re.sub(r"^\d+[.)]\s+", "", item)
        if item:
            lines.append(item)

    if len(lines) > 1:
        return lines[:MAX_TASKS_PER_PROPOSAL]

    parts = [p.strip() for p in re.split(r"\s*\|\|\s*", text) if p.strip()]
    if len(parts) <= 1:
        parts = [text]

    return parts[:MAX_TASKS_PER_PROPOSAL]


def _extract_nl_mtask_objective(raw_text: str) -> str:
    text = (raw_text or "").strip()
    if not text:
        return ""

    m = re.search(r"mtask\s*(?:to|for|that|:|-)\s*(.+)$", text, re.IGNORECASE)
    if m:
        return m.group(1).strip()

    m = re.search(r"mtask\s+(.+)$", text, re.IGNORECASE)
    if m:
        return m.group(1).strip()

    return text


def _next_task_number() -> int:
    max_num = 0
    pattern = re.compile(r"^MTASK-(\d+)\.json$")
    for f in _tasks_dir().glob("MTASK-*.json"):
        m = pattern.match(f.name)
        if not m:
            continue
        max_num = max(max_num, int(m.group(1)))
    return max_num + 1


def _run_git(args: list[str], timeout: int = 60) -> tuple[int, str, str]:
    env = dict(os.environ)
    env.setdefault("GIT_TERMINAL_PROMPT", "0")
    proc = subprocess.run(
        ["git", "-C", str(_repo_root()), *args],
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
        env=env,
    )
    return proc.returncode, (proc.stdout or "").strip(), (proc.stderr or "").strip()


def _git_push_tasks(task_paths: list[Path], proposal_id: str) -> dict[str, Any]:
    rel_paths = [str(p.relative_to(_repo_root())).replace("\\", "/") for p in task_paths]

    rc, out, err = _run_git(["add", *rel_paths])
    if rc != 0:
        return {"ok": False, "stage_error": err or out}

    rc, out, err = _run_git(["commit", "-m", f"ops({proposal_id}): approved MTASKs from cockpit"], timeout=90)
    if rc != 0:
        no_changes = "nothing to commit" in (out + "\n" + err).lower()
        if not no_changes:
            return {"ok": False, "commit_error": err or out}

    _run_git(["pull", "--rebase", "origin", "main"], timeout=90)
    rc, out, err = _run_git(["push", "origin", "main"], timeout=90)
    if rc != 0:
        return {"ok": False, "push_error": err or out}

    return {"ok": True}


def _scripts_dir() -> Path:
    return _repo_root() / "pilot_v1" / "scripts"


def _create_executor_script(task_id: str, description: str) -> Path:
    """Create a default executor script for a chat-originated MTASK."""
    scripts_dir = _scripts_dir()
    scripts_dir.mkdir(parents=True, exist_ok=True)
    script_name = f"exec_{task_id.lower().replace('-', '_')}.sh"
    script_path = scripts_dir / script_name
    safe_desc = description.replace('"', "'").replace('`', "'")
    script_content = f"""#!/usr/bin/env bash
# Auto-generated executor for {task_id}
# Issued via MIDE chat lane
set -euo pipefail

TASK_ID="{task_id}"
DESCRIPTION="{safe_desc}"

echo "[{task_id}] Starting execution..."
echo "[{task_id}] Task: $DESCRIPTION"

# ── worker logic below ─────────────────────────────────────────────────────────
# TODO: replace this stub with real implementation
echo "[{task_id}] Executor stub — task acknowledged by worker."
echo "[{task_id}] Done."
exit 0
"""
    script_path.write_text(script_content, encoding="utf-8")
    return script_path


def propose_mtasks_from_text(text: str, issued_by: str, source: str, session_id: str = "") -> dict[str, Any]:
    _ensure_dirs()
    objectives = _split_objectives(text)
    if not objectives:
        return {"ok": False, "error": "No MTASK objective found after 'mtask:'"}

    proposal_id = f"PRP-{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')}-{os.getpid()}"
    payload = {
        "proposal_id": proposal_id,
        "status": "pending_approval",
        "created_at_utc": _utc_now_iso(),
        "issued_by": issued_by,
        "source": source,
        "session_id": session_id,
        "objectives": objectives,
        "max_tasks": MAX_TASKS_PER_PROPOSAL,
    }
    (_proposals_dir() / f"{proposal_id}.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")

    _append_event({
        "ts": _utc_now_iso(),
        "event": "proposal_created",
        "proposal_id": proposal_id,
        "issued_by": issued_by,
        "source": source,
        "objective_count": len(objectives),
    })

    return {
        "ok": True,
        "proposal_id": proposal_id,
        "status": "pending_approval",
        "objectives": objectives,
        "next": f"mtask approve {proposal_id}",
    }


def list_pending_proposals(limit: int = 20) -> dict[str, Any]:
    _ensure_dirs()
    pending: list[dict[str, Any]] = []
    for f in sorted(_proposals_dir().glob("PRP-*.json"), key=lambda p: p.stat().st_mtime, reverse=True):
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
        except Exception:
            continue
        if data.get("status") != "pending_approval":
            continue
        pending.append({
            "proposal_id": data.get("proposal_id", f.stem),
            "created_at_utc": data.get("created_at_utc", ""),
            "issued_by": data.get("issued_by", ""),
            "source": data.get("source", ""),
            "objective_count": len(data.get("objectives", [])),
            "objectives": data.get("objectives", []),
        })
        if len(pending) >= max(1, min(limit, 100)):
            break
    return {"ok": True, "count": len(pending), "pending": pending}


def approve_proposal(proposal_id: str, approved_by: str = "operator") -> dict[str, Any]:
    _ensure_dirs()
    proposal_path = _proposals_dir() / f"{proposal_id}.json"
    if not proposal_path.exists():
        return {"ok": False, "error": f"Proposal not found: {proposal_id}"}

    proposal = json.loads(proposal_path.read_text(encoding="utf-8"))
    if proposal.get("status") != "pending_approval":
        return {"ok": False, "error": f"Proposal is not pending: {proposal.get('status', 'unknown')}"}

    objectives = list((proposal.get("objectives") or [])[:MAX_TASKS_PER_PROPOSAL])
    if not objectives:
        return {"ok": False, "error": "Proposal has no objectives"}

    first_num = _next_task_number()
    tasks: list[dict[str, Any]] = []
    task_paths: list[Path] = []
    for i, objective in enumerate(objectives):
        task_id = f"MTASK-{first_num + i:04d}"
        script_name = f"exec_{task_id.lower().replace('-', '_')}.sh"
        executor_script = f"pilot_v1/scripts/{script_name}"
        task_payload = {
            "task_id": task_id,
            "issued_by": proposal.get("issued_by", "cockpit-ai"),
            "issued_at": _utc_now_iso(),
            "priority": "high",
            "assigned_to": WORKER_ID,
            "required_worker_id": WORKER_ID,
            "status": "approved_to_execute",
            "description": objective,
            "executor_script": executor_script,
            "dependencies": [],
            "notes": f"source={proposal.get('source', '')}; proposal_id={proposal_id}",
            "category": "brain",
        }
        path = _tasks_dir() / f"{task_id}.json"
        path.write_text(json.dumps(task_payload, indent=2), encoding="utf-8")
        task_paths.append(path)

        # Create executor script so the worker doesn't fail with "not found"
        script_path = _create_executor_script(task_id, objective)
        task_paths.append(script_path)

        tasks.append(task_payload)

        rollback_stub = {
            "task_id": task_id,
            "created_at_utc": _utc_now_iso(),
            "rollback_status": "pending_definition",
            "proposal_id": proposal_id,
            "objective": objective,
        }
        (_rollback_dir() / f"{task_id}.rollback.json").write_text(
            json.dumps(rollback_stub, indent=2), encoding="utf-8"
        )

    proposal["status"] = "approved"
    proposal["approved_at_utc"] = _utc_now_iso()
    proposal["approved_by"] = approved_by
    proposal["created_task_ids"] = [t["task_id"] for t in tasks]
    proposal_path.write_text(json.dumps(proposal, indent=2), encoding="utf-8")

    git_result = _git_push_tasks(task_paths, proposal_id)
    _append_event({
        "ts": _utc_now_iso(),
        "event": "proposal_approved",
        "proposal_id": proposal_id,
        "approved_by": approved_by,
        "task_ids": [t["task_id"] for t in tasks],
        "git_ok": bool(git_result.get("ok")),
    })

    return {
        "ok": bool(git_result.get("ok")),
        "proposal_id": proposal_id,
        "created_count": len(tasks),
        "tasks": tasks,
        "git": git_result,
    }


def process_chat_command(text: str, sender: str) -> dict[str, Any] | None:
    raw = (text or "").strip()
    lower = raw.lower()

    if lower.startswith("mtask:"):
        objective_text = raw.split(":", 1)[1].strip() if ":" in raw else ""
        return propose_mtasks_from_text(objective_text, issued_by=sender or "cockpit-ai", source="cockpit")

    if lower.startswith("mtask approve "):
        parts = raw.split(" ", 2)
        proposal_id = parts[2].strip() if len(parts) >= 3 else ""
        if not proposal_id:
            return {"ok": False, "error": "Usage: mtask approve <proposal_id>"}
        return approve_proposal(proposal_id, approved_by=sender or "cockpit-ai")

    if lower == "mtask pending":
        return list_pending_proposals(limit=20)

    # Server-side intent fallback: if user writes natural language like
    # "create a test mtask", force it into the MTASK proposal lane.
    if _NL_MTASK_CREATE_RE.search(raw):
        objective_text = _extract_nl_mtask_objective(raw)
        return propose_mtasks_from_text(objective_text, issued_by=sender or "cockpit-ai", source="cockpit")

    return None


@router.post("/propose")
def api_propose(payload: ProposeRequest) -> dict[str, Any]:
    return propose_mtasks_from_text(payload.text, payload.issued_by, payload.source, payload.session_id)


@router.post("/approve")
def api_approve(payload: ApproveRequest) -> dict[str, Any]:
    return approve_proposal(payload.proposal_id, payload.approved_by)


@router.get("/pending")
def api_pending(limit: int = 20) -> dict[str, Any]:
    return list_pending_proposals(limit=limit)

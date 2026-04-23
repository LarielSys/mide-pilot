import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter

from ..services import load_worker_services

router = APIRouter(prefix="/api/status", tags=["status"])
_FETCH_TTL_SECONDS = 4.0
_last_fetch_monotonic = 0.0


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _run_git(repo_root: Path, args: list[str]) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            ["git", "-C", str(repo_root), *args],
            capture_output=True,
            text=True,
            timeout=8,
            check=False,
        )
        return proc.returncode, (proc.stdout or "").strip()
    except Exception:
        return 1, ""


def _maybe_fetch_origin(repo_root: Path) -> None:
    global _last_fetch_monotonic
    now = time.monotonic()
    if (now - _last_fetch_monotonic) < _FETCH_TTL_SECONDS:
        return
    _run_git(repo_root, ["fetch", "origin", "main"])
    _last_fetch_monotonic = now


def _read_state_text(repo_root: Path, rel_path: str) -> tuple[str, str]:
    _maybe_fetch_origin(repo_root)
    rc, out = _run_git(repo_root, ["show", f"origin/main:{rel_path}"])
    if rc == 0:
        return out, "origin/main"

    local_path = repo_root / rel_path
    if local_path.exists():
        return local_path.read_text(encoding="utf-8", errors="replace"), "local"

    return "", "missing"


def _parse_event_timestamp(line: str):
    token = line.split(" | ", 1)[0].strip()
    if not token:
        return None

    token = token.replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(token)
    except ValueError:
        return None

    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)

    return parsed.astimezone(timezone.utc)


def _parse_token_counter_lines(raw_text: str) -> list[dict]:
    rows: list[dict] = []
    for raw in raw_text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue

        parts = [p.strip() for p in line.split("|")]
        if len(parts) != 12:
            continue

        task_id = parts[0]
        if not task_id.startswith("MTASK-"):
            continue

        try:
            row = {
                "task_id": task_id,
                "ollama_build": int(parts[1]),
                "ollama_debug": int(parts[2]),
                "ollama_fix": int(parts[3]),
                "vs_build": int(parts[4]),
                "vs_debug": int(parts[5]),
                "vs_fix": int(parts[6]),
                "ollama_total": int(parts[7]),
                "vs_total": int(parts[8]),
                "total_tokens": int(parts[9]),
                "est_cost_usd": float(parts[10]),
                "updated_utc": parts[11],
            }
        except ValueError:
            continue

        rows.append(row)

    rows.sort(key=lambda x: x["task_id"], reverse=True)
    return rows


@router.get("/runtime")
def get_runtime_status() -> dict:
    repo_root = _repo_root()
    services = load_worker_services(repo_root)

    code_server_url = (
        services.get("code_server_url")
        or services.get("codeserver_url")
        or services.get("code_server")
        or (services.get("services") or {}).get("code_server_url")
        or (services.get("services") or {}).get("codeserver_url")
        or ""
    )

    return {
        "backend": {
            "status": "ok",
            "repo_root": str(repo_root),
            "execute_routes": {
                "local": "/api/execute/local",
                "remote": "/api/execute/remote",
            },
        },
        "worker": {
            "remote_url_available": bool(code_server_url),
            "remote_url": code_server_url,
        },
        "cost_mode": {
            "inference_policy": "ollama_local_first",
            "notes": "Use local Ollama for chat/summaries; reserve paid endpoints for exceptions.",
        },
    }


@router.get("/sync-health")
def get_sync_health() -> dict:
    repo_root = _repo_root()
    rel_sync_error = "pilot_v1/state/worker_autopilot_git_sync_last_error.txt"
    sync_error_text, sync_error_source = _read_state_text(repo_root, rel_sync_error)

    sync_error = "none"
    raw = sync_error_text.strip()
    if raw:
        sync_error = raw.splitlines()[0]

    _maybe_fetch_origin(repo_root)
    _, branch = _run_git(repo_root, ["rev-parse", "--abbrev-ref", "HEAD"])
    _, local_head = _run_git(repo_root, ["rev-parse", "HEAD"])
    _, origin_head = _run_git(repo_root, ["rev-parse", "origin/main"])
    _, status_short = _run_git(repo_root, ["status", "--short"])

    return {
        "worker_id": "ubuntu-worker-01",
        "sync_error": sync_error,
        "sync_error_file": str(repo_root / rel_sync_error),
        "sync_error_source": sync_error_source,
        "branch": branch or "unknown",
        "local_head": local_head,
        "origin_head": origin_head,
        "local_head_short": (local_head[:8] if local_head else "unknown"),
        "origin_head_short": (origin_head[:8] if origin_head else "unknown"),
        "heads_match": bool(local_head and origin_head and local_head == origin_head),
        "working_tree": "clean" if not status_short else "dirty",
        "working_tree_short": status_short,
        "reported_at_utc": _utc_now_iso(),
    }


def get_sync_cadence() -> dict:
    repo_root = _repo_root()
    rel_event_file = "pilot_v1/state/worker_autopilot_events.log"
    events_text, source = _read_state_text(repo_root, rel_event_file)
    event_file = repo_root / rel_event_file

    if not events_text:
        return {
            "samples": 0,
            "deltas_seconds": [],
            "gate_3x60_pass": False,
            "status": "missing",
            "source_file": str(event_file),
            "source": source,
            "reported_at_utc": _utc_now_iso(),
        }

    stamps = []
    for line in events_text.splitlines():
        parsed = _parse_event_timestamp(line)
        if parsed is None:
            continue
        stamps.append(parsed)
        if len(stamps) >= 4:
            break

    deltas = [int((stamps[i] - stamps[i + 1]).total_seconds()) for i in range(len(stamps) - 1)]
    gate = len(deltas) >= 3 and all(55 <= d <= 65 for d in deltas[:3])
    status = "pass" if gate else ("insufficient" if len(deltas) < 3 else "drift")

    return {
        "samples": len(stamps),
        "deltas_seconds": deltas,
        "gate_3x60_pass": gate,
        "status": status,
        "source_file": str(event_file),
        "source": source,
        "reported_at_utc": _utc_now_iso(),
    }


@router.get("/worker-log")
def get_worker_log() -> dict:
    repo_root = _repo_root()
    rel_status = "pilot_v1/state/worker_autopilot_status.json"
    rel_events = "pilot_v1/state/worker_autopilot_events.log"

    status_text, status_source = _read_state_text(repo_root, rel_status)
    events_text, events_source = _read_state_text(repo_root, rel_events)

    status = {}
    if status_text:
        try:
            status = json.loads(status_text)
        except json.JSONDecodeError:
            status = {}

    recent_events = []
    if events_text:
        recent_events = [line for line in events_text.splitlines() if line.strip()][:40]

    stale_seconds = None
    last_run_utc = status.get("last_run_utc")
    if isinstance(last_run_utc, str) and last_run_utc:
        try:
            parsed = datetime.fromisoformat(last_run_utc.replace("Z", "+00:00"))
            stale_seconds = int((datetime.now(timezone.utc) - parsed.astimezone(timezone.utc)).total_seconds())
        except ValueError:
            stale_seconds = None

    return {
        "worker_name": status.get("worker_name", ""),
        "worker_id": status.get("worker_id", ""),
        "mode": status.get("mode", ""),
        "poll_seconds": status.get("poll_seconds", ""),
        "last_run_utc": status.get("last_run_utc", ""),
        "last_run_local": status.get("last_run_local", ""),
        "log_timezone": status.get("log_timezone", ""),
        "last_task_processed": status.get("last_task_processed", ""),
        "note": status.get("note", ""),
        "status_source": status_source,
        "events_source": events_source,
        "events_count": len(recent_events),
        "recent_events": recent_events,
        "stale_seconds": stale_seconds,
        "reported_at_utc": _utc_now_iso(),
    }


@router.get("/token-counters")
def get_token_counters() -> dict:
    repo_root = _repo_root()
    rel_counter = "pilot_v1/customide/TOKEN_COUNTER_TASKS.txt"
    raw_text, source = _read_state_text(repo_root, rel_counter)

    rows = _parse_token_counter_lines(raw_text)
    ollama_total = sum(r["ollama_total"] for r in rows)
    vs_total = sum(r["vs_total"] for r in rows)
    token_total = sum(r["total_tokens"] for r in rows)
    cost_total = round(sum(r["est_cost_usd"] for r in rows), 6)

    return {
        "source": source,
        "source_file": str(repo_root / rel_counter),
        "rows": rows[:30],
        "summary": {
            "tasks_tracked": len(rows),
            "ollama_tokens_total": ollama_total,
            "vs_tokens_total": vs_total,
            "all_tokens_total": token_total,
            "estimated_cost_usd_total": cost_total,
        },
        "reported_at_utc": _utc_now_iso(),
    }


@router.get("/bundle")
def get_status_bundle() -> dict:
    return {
        "runtime": get_runtime_status(),
        "sync_health": get_sync_health(),
        "sync_cadence": get_sync_cadence(),
        "worker_log": get_worker_log(),
        "token_counters": get_token_counters(),
    }

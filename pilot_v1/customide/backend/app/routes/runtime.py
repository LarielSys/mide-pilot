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
    # Prefer local state files (seeded into container by the worker) over
    # origin/main, which can be stale when the container cannot fetch.
    for candidate in (Path("/") / rel_path, repo_root / rel_path):
        if candidate.exists():
            try:
                return candidate.read_text(encoding="utf-8", errors="replace"), "local"
            except OSError:
                pass

    _maybe_fetch_origin(repo_root)
    rc, out = _run_git(repo_root, ["show", f"origin/main:{rel_path}"])
    if rc == 0:
        return out, "origin/main"

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
            "notes": "Use Ollama for both chat and coding in the local IDE.",
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
    for line in reversed(events_text.splitlines()):
        parsed = _parse_event_timestamp(line)
        if parsed is None:
            continue
        stamps.append(parsed)
        if len(stamps) >= 4:
            break
    stamps.reverse()  # back to chronological order for delta calc

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
        # events.log is written newest-first by the worker, so take the first 40 lines.
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
    """Per-MTASK token counters, derived from each result.json's `tokens` block.

    The worker autopilot writes prompt_eval_count / eval_count / output sizes
    extracted from the executor's stdout (Ollama API responses). Tasks that
    didn't call ollama show zero token totals but still report output_chars.
    """
    stream = get_mtask_stream()
    rows = []
    ollama_total = 0
    eval_total = 0
    prompt_total = 0
    output_chars_total = 0
    ollama_calls_total = 0
    for e in stream.get("entries", []):
        tk = e.get("tokens") or {}
        prompt = int(tk.get("prompt_eval_count", 0) or 0)
        eval_c = int(tk.get("eval_count", 0) or 0)
        total = int(tk.get("total_tokens", 0) or 0) or (prompt + eval_c)
        rows.append({
            "task_id": e.get("task_id", ""),
            "execution_status": e.get("execution_status", ""),
            "ollama_model": tk.get("ollama_model", "") or "",
            "ollama_calls": int(tk.get("ollama_calls", 0) or 0),
            "prompt_eval_count": prompt,
            "eval_count": eval_c,
            "total_tokens": total,
            "ollama_total": total,  # legacy field name for older frontend
            "vs_total": 0,
            "output_chars": int(tk.get("output_chars", 0) or 0),
            "output_lines": int(tk.get("output_lines", 0) or 0),
            "ollama_total_duration_ms": int(tk.get("ollama_total_duration_ms", 0) or 0),
            "est_cost_usd": 0.0,
            "updated_utc": e.get("result_timestamp_utc", ""),
        })
        ollama_total += total
        prompt_total += prompt
        eval_total += eval_c
        output_chars_total += int(tk.get("output_chars", 0) or 0)
        ollama_calls_total += int(tk.get("ollama_calls", 0) or 0)

    return {
        "source": "mtask-results",
        "source_file": "pilot_v1/results/MTASK-*.result.json",
        "rows": rows[:30],
        "summary": {
            "tasks_tracked": len(rows),
            "ollama_tokens_total": ollama_total,
            "prompt_eval_total": prompt_total,
            "eval_count_total": eval_total,
            "ollama_calls_total": ollama_calls_total,
            "output_chars_total": output_chars_total,
            "vs_tokens_total": 0,
            "all_tokens_total": ollama_total,
            "estimated_cost_usd_total": 0.0,
        },
        "reported_at_utc": _utc_now_iso(),
    }


_MTASK_STREAM_TTL_SECONDS = 8.0
_mtask_stream_cache: dict = {"ts": 0.0, "data": None}


def _read_origin_blob(repo_root: Path, rel_path: str) -> str:
    rc, out = _run_git(repo_root, ["show", f"origin/main:{rel_path}"])
    return out if rc == 0 else ""


def _excerpt(text: str, max_lines: int = 18, max_chars: int = 1200) -> str:
    if not text:
        return ""
    lines = text.splitlines()
    if len(lines) > max_lines:
        lines = lines[:max_lines] + [f"... (+{len(text.splitlines()) - max_lines} more lines)"]
    snippet = "\n".join(lines)
    if len(snippet) > max_chars:
        snippet = snippet[:max_chars] + " …(truncated)"
    return snippet


@router.get("/mtask-stream")
def get_mtask_stream() -> dict:
    now_mono = time.monotonic()
    cached = _mtask_stream_cache.get("data")
    if cached and (now_mono - _mtask_stream_cache.get("ts", 0.0)) < _MTASK_STREAM_TTL_SECONDS:
        return cached

    repo_root = _repo_root()
    _maybe_fetch_origin(repo_root)

    # Ordered list of (timestamp, commit, task_path) for most recently added MTASK-*.json files.
    rc, out = _run_git(
        repo_root,
        [
            "log",
            "-200",
            "--diff-filter=A",
            "--name-only",
            "--pretty=format:__C__%ct|%H",
            "origin/main",
            "--",
            "pilot_v1/tasks/",
        ],
    )

    entries: list[dict] = []
    seen_tasks: set[str] = set()
    if rc == 0 and out:
        current_ts = 0
        current_commit = ""
        for line in out.splitlines():
            line = line.strip()
            if not line:
                continue
            if line.startswith("__C__"):
                try:
                    payload = line[len("__C__"):]
                    ts_str, commit = payload.split("|", 1)
                    current_ts = int(ts_str)
                    current_commit = commit.strip()
                except Exception:
                    current_ts = 0
                    current_commit = ""
                continue
            if not line.endswith(".json"):
                continue
            fname = line.rsplit("/", 1)[-1]
            if not fname.startswith("MTASK-"):
                continue
            task_id = fname[:-5]  # strip .json
            if task_id in seen_tasks:
                continue
            seen_tasks.add(task_id)

            task_text = _read_origin_blob(repo_root, line)
            task_obj: dict = {}
            if task_text:
                try:
                    task_obj = json.loads(task_text)
                except json.JSONDecodeError:
                    task_obj = {}

            executor_rel = (task_obj.get("executor_script") or "").strip()
            script_text = ""
            if executor_rel:
                script_text = _read_origin_blob(repo_root, executor_rel)
            script_excerpt = _excerpt(script_text)

            result_rel = f"pilot_v1/results/{task_id}.result.json"
            result_text = _read_origin_blob(repo_root, result_rel)
            result_obj: dict = {}
            if result_text:
                try:
                    result_obj = json.loads(result_text)
                except json.JSONDecodeError:
                    result_obj = {}

            execution_status = (result_obj.get("execution_status") or "pending").lower()
            tokens_obj = result_obj.get("tokens") or {}
            entries.append({
                "task_id": task_id,
                "issued_by": task_obj.get("issued_by", ""),
                "issued_at_utc": task_obj.get("issued_at", ""),
                "assigned_to": task_obj.get("assigned_to", ""),
                "priority": task_obj.get("priority", ""),
                "category": task_obj.get("category", ""),
                "description": task_obj.get("description", ""),
                "executor_script": executor_rel,
                "executor_excerpt": script_excerpt,
                "execution_status": execution_status,
                "result_summary": result_obj.get("summary", ""),
                "stdout_excerpt": _excerpt(result_obj.get("stdout_excerpt", ""), max_lines=10, max_chars=600),
                "stderr_excerpt": _excerpt(result_obj.get("stderr_excerpt", ""), max_lines=10, max_chars=600),
                "result_timestamp_utc": result_obj.get("timestamp_utc", ""),
                "tokens": {
                    "prompt_eval_count": int(tokens_obj.get("prompt_eval_count", 0) or 0),
                    "eval_count": int(tokens_obj.get("eval_count", 0) or 0),
                    "total_tokens": int(tokens_obj.get("total_tokens", 0) or 0),
                    "ollama_calls": int(tokens_obj.get("ollama_calls", 0) or 0),
                    "ollama_model": tokens_obj.get("ollama_model", "") or "",
                    "ollama_total_duration_ms": int(tokens_obj.get("ollama_total_duration_ms", 0) or 0),
                    "output_chars": int(tokens_obj.get("output_chars", 0) or 0),
                    "output_lines": int(tokens_obj.get("output_lines", 0) or 0),
                },
                "added_commit": current_commit,
                "added_epoch": current_ts,
            })
            if len(entries) >= 30:
                break

    summary = {
        "total": len(entries),
        "completed": sum(1 for e in entries if e["execution_status"] == "completed"),
        "failed": sum(1 for e in entries if e["execution_status"] == "failed"),
        "pending": sum(1 for e in entries if e["execution_status"] not in ("completed", "failed")),
    }

    data = {
        "entries": entries,
        "summary": summary,
        "reported_at_utc": _utc_now_iso(),
    }
    _mtask_stream_cache["ts"] = now_mono
    _mtask_stream_cache["data"] = data
    return data


@router.get("/bundle")
def get_status_bundle() -> dict:
    return {
        "runtime": get_runtime_status(),
        "sync_health": get_sync_health(),
        "sync_cadence": get_sync_cadence(),
        "worker_log": get_worker_log(),
        "token_counters": get_token_counters(),
        "mtask_stream": get_mtask_stream(),
    }

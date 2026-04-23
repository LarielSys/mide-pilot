from pathlib import Path

from fastapi import APIRouter

from ..services import load_worker_services

router = APIRouter(prefix="/api/status", tags=["status"])


@router.get("/runtime")
def get_runtime_status() -> dict:
    repo_root = Path(__file__).resolve().parents[3]
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
    }


@router.get("/sync-health")
def get_sync_health() -> dict:


def get_sync_cadence() -> dict:
    from datetime import datetime

    repo_root = Path(__file__).resolve().parents[3]
    event_file = repo_root / "pilot_v1/state/worker_autopilot_events.log"

    if not event_file.exists():
        return {
            "samples": 0,
            "deltas_seconds": [],
            "gate_3x60_pass": False,
            "status": "missing",
            "source_file": str(event_file),
        }

    lines = event_file.read_text(encoding="utf-8", errors="replace").splitlines()
    stamps = []
    for line in lines:
        if len(line) >= 20 and line[19] == "Z":
            head = line[:20]
            try:
                stamps.append(datetime.strptime(head, "%Y-%m-%dT%H:%M:%SZ"))
            except ValueError:
                continue
        if len(stamps) >= 4:
            break

    deltas = []
    for i in range(len(stamps) - 1):
        deltas.append(int((stamps[i] - stamps[i + 1]).total_seconds()))

    gate = len(deltas) >= 3 and all(55 <= d <= 65 for d in deltas[:3])
    status = "pass" if gate else ("insufficient" if len(deltas) < 3 else "drift")

    return {
        "samples": len(stamps),
        "deltas_seconds": deltas,
        "gate_3x60_pass": gate,
        "status": status,
        "source_file": str(event_file),
    }
    repo_root = Path(__file__).resolve().parents[3]
    sync_error_file = repo_root / "pilot_v1/state/worker_autopilot_git_sync_last_error.txt"

    sync_error = "none"
    if sync_error_file.exists():
        raw = sync_error_file.read_text(encoding="utf-8", errors="replace").strip()
        if raw:
            sync_error = raw.splitlines()[0]

    return {
        "worker_id": "ubuntu-worker-01",
        "sync_error": sync_error,
        "sync_error_file": str(sync_error_file),
    }


@router.get("/bundle")
def get_status_bundle() -> dict:
    return {
        "runtime": get_runtime_status(),
        "sync_health": get_sync_health(),
        "sync_cadence": get_sync_cadence(),
    }

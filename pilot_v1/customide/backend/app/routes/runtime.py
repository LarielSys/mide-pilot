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

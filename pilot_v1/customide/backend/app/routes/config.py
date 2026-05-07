from pathlib import Path

from fastapi import APIRouter

from ..services import load_worker_services

router = APIRouter(prefix="/api/config", tags=["config"])


@router.get("/services")
def get_services() -> dict:
    repo_root = Path(__file__).resolve().parents[3]
    return load_worker_services(repo_root)

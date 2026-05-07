from pathlib import Path

from fastapi import APIRouter

from ..services import load_worker_services

router = APIRouter(prefix="/api/config", tags=["config"])


@router.get("/services")
def get_services() -> dict:
    p = Path(__file__).resolve()
    repo_root = next((q for q in p.parents if (q / ".git").exists()), p.parents[5])
    return load_worker_services(repo_root)

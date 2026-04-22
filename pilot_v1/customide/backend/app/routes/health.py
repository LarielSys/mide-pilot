from datetime import datetime, timezone

from fastapi import APIRouter

from ..settings import settings

router = APIRouter(prefix="/health", tags=["health"])


@router.get("")
def health() -> dict:
    return {
        "status": "ok",
        "service": settings.app_name,
        "env": settings.app_env,
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
    }

import json
from pathlib import Path
from typing import Any, Dict

from .settings import settings


def load_worker_services(repo_root: Path) -> Dict[str, Any]:
    cfg = repo_root / settings.worker_services_config_path
    if not cfg.exists():
        return {
            "status": "missing",
            "path": str(cfg),
            "services": {},
        }

    with cfg.open("r", encoding="utf-8") as f:
        data = json.load(f)

    return {
        "status": "ok",
        "path": str(cfg),
        "services": data,
    }

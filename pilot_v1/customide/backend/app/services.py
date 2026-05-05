import json
from pathlib import Path
from typing import Any, Dict

from .settings import settings


def load_worker_services(repo_root: Path) -> Dict[str, Any]:
    configured = Path(settings.worker_services_config_path)

    if configured.is_absolute():
        cfg = configured
    else:
        cfg = repo_root / configured
        if not cfg.exists():
            cfg = None
            for base in (repo_root, *repo_root.parents):
                candidate = base / configured
                if candidate.exists():
                    cfg = candidate
                    break
            if cfg is None:
                cfg = repo_root / configured

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

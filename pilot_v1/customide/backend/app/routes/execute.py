import shlex
import subprocess
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from ..services import load_worker_services

router = APIRouter(prefix="/api/execute", tags=["execute"])

MAX_OUTPUT_CHARS = 4000
ALLOWED_LOCAL_COMMANDS = {
    "echo",
    "pwd",
    "ls",
    "cat",
    "python3",
    "python",
}


class LocalExecuteRequest(BaseModel):
    command: str = Field(min_length=1, max_length=240)
    cwd: Optional[str] = None
    timeout_seconds: int = Field(default=20, ge=1, le=30)


class RemoteExecuteRequest(BaseModel):
    command: str = Field(min_length=1, max_length=240)
    host: Optional[str] = Field(default=None, max_length=200)
    user: Optional[str] = Field(default=None, max_length=120)
    key_path: Optional[str] = Field(default=None, max_length=260)
    timeout_seconds: int = Field(default=25, ge=1, le=35)
    use_worker_config: bool = True


def _safe_cwd(path_str: Optional[str]) -> Path:
    repo_root = Path(__file__).resolve().parents[4]
    if not path_str:
        return repo_root

    p = Path(path_str).expanduser().resolve()
    if not str(p).startswith(str(repo_root)):
        raise HTTPException(status_code=400, detail="cwd must stay inside repo root")
    return p


def _parse_local_command(command: str) -> list[str]:
    try:
        args = shlex.split(command)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=f"Invalid command syntax: {exc}") from exc

    if not args:
        raise HTTPException(status_code=400, detail="Empty command")

    base = args[0]
    if base not in ALLOWED_LOCAL_COMMANDS:
        allowed = ", ".join(sorted(ALLOWED_LOCAL_COMMANDS))
        raise HTTPException(status_code=400, detail=f"Command '{base}' is not allowed. Allowed: {allowed}")

    return args


def _resolve_remote_target(payload: RemoteExecuteRequest) -> tuple[str, str, Optional[str]]:
    host = payload.host
    user = payload.user
    key_path = payload.key_path

    if payload.use_worker_config:
        repo_root = Path(__file__).resolve().parents[4]
        services = load_worker_services(repo_root)

        host = host or services.get("worker_host") or services.get("host")
        user = user or services.get("worker_user") or services.get("ssh_user")
        key_path = key_path or services.get("ssh_key_path")

        services_obj = services.get("services") or {}
        host = host or services_obj.get("worker_host")
        user = user or services_obj.get("worker_user")
        key_path = key_path or services_obj.get("ssh_key_path")

    if not host or not user:
        raise HTTPException(status_code=400, detail="Remote target missing host/user and no worker config provided")

    return host, user, key_path


@router.post("/local")
def execute_local(payload: LocalExecuteRequest) -> dict:
    cwd = _safe_cwd(payload.cwd)
    args = _parse_local_command(payload.command)

    try:
        proc = subprocess.run(
            args,
            cwd=str(cwd),
            capture_output=True,
            text=True,
            timeout=payload.timeout_seconds,
        )
    except subprocess.TimeoutExpired as exc:
        raise HTTPException(status_code=408, detail=f"Local command timed out: {exc}") from exc

    return {
        "command": payload.command,
        "argv": args,
        "cwd": str(cwd),
        "exit_code": proc.returncode,
        "stdout": proc.stdout[-MAX_OUTPUT_CHARS:],
        "stderr": proc.stderr[-MAX_OUTPUT_CHARS:],
        "ok": proc.returncode == 0,
    }


@router.post("/remote")
def execute_remote(payload: RemoteExecuteRequest) -> dict:
    host, user, key_path = _resolve_remote_target(payload)

    ssh_cmd = [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=12",
    ]

    if key_path:
        ssh_cmd.extend(["-i", key_path])

    target = f"{user}@{host}"
    ssh_cmd.extend([target, payload.command])

    try:
        proc = subprocess.run(
            ssh_cmd,
            capture_output=True,
            text=True,
            timeout=payload.timeout_seconds,
        )
    except subprocess.TimeoutExpired as exc:
        raise HTTPException(status_code=408, detail=f"Remote command timed out: {exc}") from exc

    return {
        "target": target,
        "command": payload.command,
        "exit_code": proc.returncode,
        "stdout": proc.stdout[-MAX_OUTPUT_CHARS:],
        "stderr": proc.stderr[-MAX_OUTPUT_CHARS:],
        "ssh_command": " ".join(shlex.quote(x) for x in ssh_cmd),
        "ok": proc.returncode == 0,
    }

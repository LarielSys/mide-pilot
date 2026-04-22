import shlex
import subprocess
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

router = APIRouter(prefix="/api/execute", tags=["execute"])


class LocalExecuteRequest(BaseModel):
    command: str = Field(min_length=1, max_length=200)
    cwd: Optional[str] = None


class RemoteExecuteRequest(BaseModel):
    command: str = Field(min_length=1, max_length=200)
    host: str = Field(min_length=1, max_length=200)
    user: str = Field(min_length=1, max_length=120)
    key_path: Optional[str] = None


def _safe_cwd(path_str: Optional[str]) -> Path:
    base = Path.cwd()
    if not path_str:
        return base

    p = Path(path_str).expanduser().resolve()
    if not str(p).startswith(str(base)):
        raise HTTPException(status_code=400, detail="cwd must stay inside repo root")
    return p


@router.post("/local")
def execute_local(payload: LocalExecuteRequest) -> dict:
    cwd = _safe_cwd(payload.cwd)

    try:
        proc = subprocess.run(
            payload.command,
            cwd=str(cwd),
            shell=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except subprocess.TimeoutExpired as exc:
        raise HTTPException(status_code=408, detail=f"Local command timed out: {exc}") from exc

    return {
        "command": payload.command,
        "cwd": str(cwd),
        "exit_code": proc.returncode,
        "stdout": proc.stdout[-4000:],
        "stderr": proc.stderr[-4000:],
    }


@router.post("/remote")
def execute_remote(payload: RemoteExecuteRequest) -> dict:
    ssh_cmd = [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=12",
    ]

    if payload.key_path:
        ssh_cmd.extend(["-i", payload.key_path])

    target = f"{payload.user}@{payload.host}"
    ssh_cmd.extend([target, payload.command])

    try:
        proc = subprocess.run(
            ssh_cmd,
            capture_output=True,
            text=True,
            timeout=35,
        )
    except subprocess.TimeoutExpired as exc:
        raise HTTPException(status_code=408, detail=f"Remote command timed out: {exc}") from exc

    return {
        "target": target,
        "command": payload.command,
        "exit_code": proc.returncode,
        "stdout": proc.stdout[-4000:],
        "stderr": proc.stderr[-4000:],
        "ssh_command": " ".join(shlex.quote(x) for x in ssh_cmd),
    }

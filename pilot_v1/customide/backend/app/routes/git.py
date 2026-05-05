from pathlib import Path
from typing import Optional
import os
import subprocess

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

router = APIRouter(prefix="/api/git", tags=["git"])


def _run_git(repo_root: Path, args: list[str], timeout: int = 25) -> tuple[int, str, str]:
    env = dict(os.environ)
    env.setdefault("GIT_TERMINAL_PROMPT", "0")
    proc = subprocess.run(
        ["git", "-C", str(repo_root), *args],
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
        env=env,
    )
    return proc.returncode, (proc.stdout or "").strip(), (proc.stderr or "").strip()


def _resolve_git_root() -> Path:
    candidates = [
        Path(__file__).resolve().parents[3],
        Path(__file__).resolve().parents[4],
        Path(__file__).resolve().parents[5],
    ]
    for candidate in candidates:
        rc, out, _ = _run_git(candidate, ["rev-parse", "--show-toplevel"], timeout=8)
        if rc == 0 and out:
            return Path(out)
    raise HTTPException(status_code=400, detail="No git repository found for backend workspace")


def _current_branch(repo_root: Path) -> str:
    rc, out, _ = _run_git(repo_root, ["rev-parse", "--abbrev-ref", "HEAD"], timeout=8)
    if rc != 0:
        return ""
    return out


def _upstream_branch(repo_root: Path) -> str:
    rc, out, _ = _run_git(repo_root, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], timeout=8)
    if rc != 0:
        return ""
    return out


def _remotes(repo_root: Path) -> dict[str, str]:
    rc, out, _ = _run_git(repo_root, ["remote", "-v"], timeout=8)
    if rc != 0:
        return {}

    remotes: dict[str, str] = {}
    for raw in out.splitlines():
        line = raw.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 3:
            continue
        name, url, op = parts[0], parts[1], parts[2]
        if "(fetch)" in op:
            remotes[name] = url
    return remotes


class GitConnectRequest(BaseModel):
    remote_url: str = Field(min_length=5, max_length=400)
    remote_name: str = Field(default="origin", min_length=1, max_length=80)


class GitActionRequest(BaseModel):
    remote_name: str = Field(default="origin", min_length=1, max_length=80)
    branch: Optional[str] = Field(default=None, max_length=120)
    set_upstream: bool = True


@router.get("/status")
def git_status() -> dict:
    repo_root = _resolve_git_root()

    rc_status, status_short, status_err = _run_git(repo_root, ["status", "--short"], timeout=8)
    if rc_status != 0:
        raise HTTPException(status_code=500, detail=f"git status failed: {status_err or 'unknown error'}")

    branch = _current_branch(repo_root)
    upstream = _upstream_branch(repo_root)
    remotes = _remotes(repo_root)

    ahead = 0
    behind = 0
    if upstream:
        rc, out, _ = _run_git(repo_root, ["rev-list", "--left-right", "--count", f"HEAD...{upstream}"], timeout=8)
        if rc == 0 and out:
            parts = out.split()
            if len(parts) == 2:
                ahead = int(parts[0])
                behind = int(parts[1])

    return {
        "repo_root": str(repo_root),
        "branch": branch or "unknown",
        "upstream": upstream or "",
        "working_tree": "clean" if not status_short else "dirty",
        "working_tree_short": status_short,
        "remotes": remotes,
        "has_origin": "origin" in remotes,
        "ahead": ahead,
        "behind": behind,
    }


@router.post("/connect")
def git_connect(payload: GitConnectRequest) -> dict:
    repo_root = _resolve_git_root()
    remotes = _remotes(repo_root)

    if payload.remote_name in remotes:
        rc, _, err = _run_git(repo_root, ["remote", "set-url", payload.remote_name, payload.remote_url])
        action = "set-url"
    else:
        rc, _, err = _run_git(repo_root, ["remote", "add", payload.remote_name, payload.remote_url])
        action = "add"

    if rc != 0:
        raise HTTPException(status_code=400, detail=f"git remote {action} failed: {err or 'unknown error'}")

    return {
        "ok": True,
        "remote_name": payload.remote_name,
        "remote_url": payload.remote_url,
        "action": action,
    }


@router.post("/fetch")
def git_fetch(payload: GitActionRequest) -> dict:
    repo_root = _resolve_git_root()
    rc, out, err = _run_git(repo_root, ["fetch", payload.remote_name], timeout=40)
    if rc != 0:
        raise HTTPException(status_code=400, detail=f"git fetch failed: {err or out or 'unknown error'}")

    return {"ok": True, "command": f"git fetch {payload.remote_name}", "stdout": out, "stderr": err}


@router.post("/pull")
def git_pull(payload: GitActionRequest) -> dict:
    repo_root = _resolve_git_root()
    branch = payload.branch or _current_branch(repo_root)
    if not branch:
        raise HTTPException(status_code=400, detail="Unable to resolve current branch")

    rc, out, err = _run_git(repo_root, ["pull", "--ff-only", payload.remote_name, branch], timeout=60)
    if rc != 0:
        raise HTTPException(status_code=400, detail=f"git pull failed: {err or out or 'unknown error'}")

    return {
        "ok": True,
        "command": f"git pull --ff-only {payload.remote_name} {branch}",
        "stdout": out,
        "stderr": err,
    }


@router.post("/push")
def git_push(payload: GitActionRequest) -> dict:
    repo_root = _resolve_git_root()
    branch = payload.branch or _current_branch(repo_root)
    if not branch:
        raise HTTPException(status_code=400, detail="Unable to resolve current branch")

    args = ["push"]
    if payload.set_upstream:
        args.append("-u")
    args.extend([payload.remote_name, f"HEAD:{branch}"])

    rc, out, err = _run_git(repo_root, args, timeout=60)
    if rc != 0:
        raise HTTPException(status_code=400, detail=f"git push failed: {err or out or 'unknown error'}")

    return {
        "ok": True,
        "command": "git " + " ".join(args),
        "stdout": out,
        "stderr": err,
    }

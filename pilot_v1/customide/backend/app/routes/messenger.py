"""Messenger proxy — forwards POST /api/messenger to the Ole Green relay."""

import httpx
from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

router = APIRouter(prefix="/api/messenger", tags=["messenger"])

_RELAY_URL = "http://127.0.0.1:8787/messenger"


@router.post("")
async def proxy_messenger(request: Request) -> JSONResponse:
    try:
        body = await request.json()
    except Exception:
        body = {}

    try:
        async with httpx.AsyncClient(timeout=30) as client:
            resp = await client.post(_RELAY_URL, json=body)
        return JSONResponse(content=resp.json(), status_code=resp.status_code)
    except httpx.ConnectError:
        return JSONResponse(
            content={"ok": False, "error": "Relay offline (connection refused on port 8787)"},
            status_code=503,
        )
    except Exception as exc:
        return JSONResponse(
            content={"ok": False, "error": str(exc)},
            status_code=502,
        )

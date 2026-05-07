import asyncio
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .operator_loop import run_operator_loop
from .routes import config, execute, git, health, messenger, ollama_proxy, runtime, shared_llm
from .settings import settings


@asynccontextmanager
async def lifespan(app: FastAPI):
    loop_task = asyncio.create_task(run_operator_loop())
    try:
        yield
    finally:
        loop_task.cancel()
        try:
            await loop_task
        except asyncio.CancelledError:
            pass


app = FastAPI(title=settings.app_name, lifespan=lifespan)

# Barebones interoperability: let both local and remote IDE channels
# call the same backend bridge endpoint tonight.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health.router)
app.include_router(config.router)
app.include_router(git.router)
app.include_router(ollama_proxy.router)
app.include_router(execute.router)
app.include_router(runtime.router)
app.include_router(shared_llm.router)
app.include_router(messenger.router)


@app.get("/")
def root() -> dict:
    return {
        "name": settings.app_name,
        "status": "running",
        "health": "/health",
        "runtime_status": "/api/status/runtime",
        "shared_llm": "/api/llm/chat",
    }

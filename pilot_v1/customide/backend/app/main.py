from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .routes import config, execute, health, ollama_proxy, runtime, shared_llm
from .settings import settings

app = FastAPI(title=settings.app_name)

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
app.include_router(ollama_proxy.router)
app.include_router(execute.router)
app.include_router(runtime.router)
app.include_router(shared_llm.router)


@app.get("/")
def root() -> dict:
    return {
        "name": settings.app_name,
        "status": "running",
        "health": "/health",
        "runtime_status": "/api/status/runtime",
        "shared_llm": "/api/llm/chat",
    }

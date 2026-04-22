from fastapi import FastAPI

from .routes import config, execute, health, ollama_proxy
from .settings import settings

app = FastAPI(title=settings.app_name)

app.include_router(health.router)
app.include_router(config.router)
app.include_router(ollama_proxy.router)
app.include_router(execute.router)


@app.get("/")
def root() -> dict:
    return {
        "name": settings.app_name,
        "status": "running",
        "health": "/health",
    }

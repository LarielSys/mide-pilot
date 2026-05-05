from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_name: str = "CustomIDE Backend"
    app_env: str = "development"
    app_host: str = "127.0.0.1"
    app_port: int = 5555
    # Leave empty by default so endpoint resolution can use worker1_services.json.
    ollama_url: str = ""

    # Relative to customide repo root: ../config/worker1_services.json
    worker_services_config_path: str = "../config/worker1_services.json"

    # Relative to customide repo root: shared history used by both local/remote IDE chats.
    llm_chat_history_path: str = "../state/shared_llm_chat_history.json"

    request_timeout_seconds: int = 30

    # Ollama connector knobs.
    # - CUSTOMIDE_OLLAMA_BASE_URL: base host, e.g. http://127.0.0.1:11434
    # - CUSTOMIDE_OLLAMA_GENERATE_URL: fully-qualified generate endpoint override
    # - CUSTOMIDE_OLLAMA_CHAT_URL: fully-qualified chat endpoint override
    # - CUSTOMIDE_OLLAMA_URL: legacy alias for generate endpoint/base URL
    ollama_base_url: str = "http://127.0.0.1:11434"
    ollama_generate_url: str = ""
    ollama_chat_url: str = ""
    ollama_url: str = ""

    model_config = SettingsConfigDict(env_prefix="CUSTOMIDE_", extra="ignore")


settings = Settings()

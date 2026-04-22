from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_name: str = "CustomIDE Backend"
    app_env: str = "development"
    app_host: str = "127.0.0.1"
    app_port: int = 5555

    # This file is produced by MTASK-0034 on Worker 1 and consumed by the backend.
    worker_services_config_path: str = "pilot_v1/config/worker1_services.json"

    request_timeout_seconds: int = 30

    model_config = SettingsConfigDict(env_prefix="CUSTOMIDE_", extra="ignore")


settings = Settings()

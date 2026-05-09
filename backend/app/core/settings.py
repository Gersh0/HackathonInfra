import json
from typing import Annotated

from pydantic import Field, field_validator, model_validator
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # Database Configuration - MUST be provided via environment variables
    database_url: str  # No default - REQUIRED via DATABASE_URL env var

    # Redis Configuration
    redis_url: str = "redis://redis:6379/0"

    # Application Configuration
    app_env: str = "development"
    log_level: str = "INFO"

    # Tracing Configuration
    tracing_enabled: bool = True
    tracing_service_name: str = "youtube-clone-backend"
    tracing_otlp_endpoint: str | None = None

    # JWT Configuration - MUST be provided via environment variables
    jwt_secret_key: str  # No default - REQUIRED via JWT_SECRET_KEY env var
    jwt_algorithm: str = "HS256"
    jwt_access_token_exp_minutes: int = 120
    auth_token_issuer_enabled: bool = False
    cors_allow_origins: Annotated[list[str], NoDecode] = [
        "http://localhost",
        "http://127.0.0.1",
        "http://localhost:5173",
        "http://127.0.0.1:5173",
    ]
    max_request_body_bytes: int = 10 * 1024 * 1024
    max_video_upload_bytes: int = 200 * 1024 * 1024
    max_thumbnail_upload_bytes: int = 8 * 1024 * 1024
    max_avatar_upload_bytes: int = 4 * 1024 * 1024
    max_multipart_overhead_bytes: int = 2 * 1024 * 1024
    rate_limit_window_seconds: int = 60
    rate_limit_mutation_max_requests: int = 60
    rate_limit_auth_max_requests: int = 20
    enqueue_retry_attempts: int = 3
    enqueue_retry_base_delay_seconds: float = 0.1
    default_page_size: int = 20
    max_page_size: int = 100

    # SQLAlchemy connection pool (per Gunicorn worker process)
    # Total Postgres connections ≤ backend_web_concurrency × (db_pool_size + db_max_overflow)
    db_pool_size: int = Field(default=5, ge=1)
    db_max_overflow: int = Field(default=5, ge=0)
    db_pool_timeout: int = Field(default=30, ge=1)
    db_pool_recycle: int = Field(default=1800, ge=0)

    # Redis connection pool (per backend instance)
    redis_max_connections: int = Field(default=50, ge=1)

    # anyio thread limiter — decoupled from DB pool so cache-hit-only routes can serve
    # more concurrent requests without waiting for DB connections.
    # 0 = use db_pool_size + db_max_overflow (default behaviour, no change).
    anyio_min_threads: int = Field(default=0, ge=0)

    # Cache TTL for individual video detail pages (seconds).
    # Higher values reduce cache-miss DB hits; lower values keep view counts fresher.
    video_detail_cache_ttl: int = Field(default=10, ge=1)

    @field_validator("cors_allow_origins", mode="before")
    @classmethod
    def parse_cors_allow_origins(cls, value: object) -> object:
        if isinstance(value, list):
            return [str(origin).strip() for origin in value if str(origin).strip()]

        if not isinstance(value, str):
            return value

        raw = value.strip()
        if not raw:
            return []

        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            parsed = None

        if isinstance(parsed, list):
            return [str(origin).strip() for origin in parsed if str(origin).strip()]

        origins: list[str] = []
        for part in raw.split(","):
            cleaned = part.strip().strip("[]").strip('"').strip("'")
            if cleaned:
                origins.append(cleaned)
        return origins

    @property
    def is_development_like(self) -> bool:
        return self.app_env.lower() in {"dev", "development", "local", "test"}

    @model_validator(mode="after")
    def validate_jwt_secret(self) -> "Settings":
        insecure_values = {"", "dev-change-me", "change-me", "changeme"}
        if not self.is_development_like and self.jwt_secret_key.strip().lower() in insecure_values:
            raise ValueError(
                "JWT_SECRET_KEY must be set to a strong secret when APP_ENV is not development-like"
            )
        return self


settings = Settings()

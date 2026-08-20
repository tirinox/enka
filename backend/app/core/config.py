"""Application settings, read from the environment (prefix ``ENKA_``)."""

from __future__ import annotations

import functools

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

PLACEHOLDER_SECRETS = {"change-me", "change-me-too", "change-me-as-well", ""}


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="ENKA_",
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # --- app ---------------------------------------------------------------
    app_name: str = "Enka"
    env: str = "dev"
    debug: bool = False
    log_level: str = "INFO"
    cors_origins: str = "*"

    # --- database ----------------------------------------------------------
    database_url: str = "postgresql+asyncpg://enka:enka@db:5432/enka"
    db_echo: bool = False

    # --- auth --------------------------------------------------------------
    access_secret: str = ""
    jwt_secret: str = ""
    jwt_algorithm: str = "HS256"
    jwt_ttl_hours: int = 720
    media_token_ttl_minutes: int = 5
    owner_name: str = "me"

    # Sliding-window throttle on the token endpoint. The access secret is
    # short and human-typed, so unthrottled guessing is the realistic attack.
    auth_rate_limit_attempts: int = 5
    auth_rate_limit_window_seconds: int = 60

    # --- media -------------------------------------------------------------
    audio_dir: str = "/data/audio"
    max_audio_mb: int = 25

    # --- TTS (auto-generated term audio) ------------------------------------
    tts_enabled: bool = True
    tts_model_dir: str = "/data/tts-voices"
    #: Language code -> Piper voice basename (relative to tts_model_dir; loads
    #: ``{name}.onnx`` + ``{name}.onnx.json``). Also the set of languages
    #: language-detection is allowed to guess — add a language by dropping
    #: the two voice files in and adding an entry here, no code change.
    tts_voice_map: dict[str, str] = {
        "en": "en_US-lessac-medium",
        "ru": "ru_RU-irina-medium",
    }
    #: Below this confidence, detect_language() returns None rather than
    #: guess. Meaningful only because detection is restricted to
    #: tts_voice_map's languages — see app/services/tts.py.
    tts_min_confidence: float = Field(default=0.75, ge=0.0, le=1.0)

    @field_validator("tts_voice_map", mode="before")
    @classmethod
    def _parse_voice_map(cls, value: object) -> object:
        """Accepts ``en:en_US-lessac-medium,ru:ru_RU-irina-medium`` as well as JSON."""
        if isinstance(value, str) and not value.strip().startswith("{"):
            pairs = (part.split(":", 1) for part in value.split(",") if part.strip())
            return {k.strip(): v.strip() for k, v in pairs}
        return value

    # --- FSRS --------------------------------------------------------------
    fsrs_desired_retention: float = Field(default=0.9, gt=0.0, lt=1.0)
    fsrs_maximum_interval: int = Field(default=36500, gt=0)
    fsrs_enable_fuzzing: bool = True
    fsrs_learning_steps_minutes: list[int] = [1, 10]
    fsrs_relearning_steps_minutes: list[int] = [10]

    @field_validator("fsrs_learning_steps_minutes", "fsrs_relearning_steps_minutes", mode="before")
    @classmethod
    def _split_steps(cls, value: object) -> object:
        """Accept ``1,10`` from the environment as well as a JSON list."""
        if isinstance(value, str) and not value.strip().startswith("["):
            return [int(part) for part in value.split(",") if part.strip()]
        return value

    @property
    def max_audio_bytes(self) -> int:
        return self.max_audio_mb * 1024 * 1024

    @property
    def cors_origin_list(self) -> list[str]:
        return [origin.strip() for origin in self.cors_origins.split(",") if origin.strip()]

    def validate_secrets(self) -> None:
        """Refuse to serve with placeholder credentials.

        Called at startup rather than at import so that tooling (alembic,
        ``--help``) still works on a half-configured checkout.
        """
        problems = []
        if self.access_secret.strip().lower() in PLACEHOLDER_SECRETS:
            problems.append("ENKA_ACCESS_SECRET is unset or still the placeholder")
        if self.jwt_secret.strip().lower() in PLACEHOLDER_SECRETS:
            problems.append("ENKA_JWT_SECRET is unset or still the placeholder")
        if problems:
            raise RuntimeError(
                "Refusing to start: "
                + "; ".join(problems)
                + ". Generate values with `openssl rand -hex 32` and put them in .env."
            )


@functools.lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()

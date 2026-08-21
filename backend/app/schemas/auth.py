from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, Field, field_validator


class TokenRequest(BaseModel):
    secret: str = Field(
        min_length=1,
        description="The shared secret from the server's .env (ENKA_ACCESS_SECRET).",
        examples=["a3f1c9d0e7b24856"],
    )


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_at: datetime
    scope: str = "api"


class MeResponse(BaseModel):
    owner_id: uuid.UUID
    name: str
    #: ISO 639-1 code, e.g. "ru". None until set via PATCH /auth/me — the
    #: client prompts for it the first time a translation is requested.
    native_language: str | None = None
    token_expires_at: datetime


class MeUpdate(BaseModel):
    native_language: str = Field(min_length=2, max_length=8, examples=["ru"])

    @field_validator("native_language")
    @classmethod
    def _normalize(cls, value: str) -> str:
        cleaned = value.strip().lower()
        if not cleaned:
            raise ValueError("native_language must not be blank")
        return cleaned

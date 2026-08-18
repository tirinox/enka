from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, Field


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
    token_expires_at: datetime

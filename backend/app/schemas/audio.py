from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, computed_field

from app.models.audio_clip import AudioSide


class AudioClipOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    card_id: uuid.UUID
    side: AudioSide
    original_filename: str | None
    content_type: str
    size_bytes: int
    sha256: str
    duration_ms: int | None
    sort_order: int
    created_at: datetime

    @computed_field  # type: ignore[prop-decorator]
    @property
    def url(self) -> str:
        """Where to fetch the bytes. Append ``?token=`` from
        ``POST /auth/media-token`` when using it as an ``<audio src>``."""
        return f"/api/v1/audio/{self.id}"


class AudioClipUpdate(BaseModel):
    sort_order: int | None = None
    duration_ms: int | None = Field(default=None, ge=0)

from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field


class TagCreate(BaseModel):
    name: str = Field(min_length=1, max_length=64, examples=["verbs"])
    color: str | None = Field(default=None, max_length=16, examples=["#c56b3a"])


class TagUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=64)
    color: str | None = Field(default=None, max_length=16)


class TagOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    color: str | None
    created_at: datetime


class TagWithCount(TagOut):
    card_count: int = Field(description="Cards carrying this tag, excluding deleted ones.")

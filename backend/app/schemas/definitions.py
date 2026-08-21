from __future__ import annotations

import enum

from pydantic import BaseModel


class DefinitionMode(str, enum.Enum):
    """Which kind of text to generate for a card's term."""

    SAME_LANGUAGE = "same_language"
    NATIVE_LANGUAGE = "native_language"


class DefinitionGenerateRequest(BaseModel):
    mode: DefinitionMode


class DefinitionGenerateResponse(BaseModel):
    #: Never persisted server-side — the client saves it via the normal
    #: PATCH /cards/{id} if it wants to keep it.
    definition: str

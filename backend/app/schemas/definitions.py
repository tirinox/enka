from __future__ import annotations

import enum

from pydantic import BaseModel, Field, field_validator


class DefinitionMode(str, enum.Enum):
    """Which kind of text to generate for a term."""

    SAME_LANGUAGE = "same_language"
    NATIVE_LANGUAGE = "native_language"


class DefinitionGenerateRequest(BaseModel):
    """Works on a term that hasn't been saved as a card yet — the Add flow
    in both clients uses this directly, not just card editing."""

    term: str = Field(min_length=1, max_length=10_000, examples=["das Fenster"])
    mode: DefinitionMode

    @field_validator("term")
    @classmethod
    def _term_not_blank(cls, value: str) -> str:
        cleaned = value.strip()
        if not cleaned:
            raise ValueError("term must not be blank")
        return cleaned


class DefinitionGenerateResponse(BaseModel):
    #: Never persisted server-side — the client saves it itself (as the
    #: term/definition it's about to create, or via PATCH /cards/{id}) if
    #: it wants to keep it.
    definition: str

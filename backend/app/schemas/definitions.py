from __future__ import annotations

import enum
from typing import Literal

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


class TermCheck(BaseModel):
    """Something worth a second look about the term itself. Advisory only:
    the client shows it and the user may save the term unchanged anyway."""

    issue: Literal["misspelled", "outdated", "vulgar"]
    #: One short sentence saying what is wrong, for the warning line.
    note: str = Field(max_length=300)
    #: The corrected / current / neutral form, when there is one.
    suggestion: str | None = Field(default=None, max_length=200)


class DefinitionGenerateResponse(BaseModel):
    #: Never persisted server-side — the client saves it itself (as the
    #: term/definition it's about to create, or via PATCH /cards/{id}) if
    #: it wants to keep it.
    definition: str
    #: Null when the term looks fine, or when the check itself failed — a
    #: check that could not run is never a reason to withhold the definition.
    term_check: TermCheck | None = None

from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.models.card import SrsState
from app.schemas.audio import AudioClipOut


def _clean(value: str | None) -> str | None:
    if value is None:
        return None
    stripped = value.strip()
    return stripped or None


class CardBase(BaseModel):
    term: str = Field(min_length=1, max_length=10_000, examples=["das Fenster"])
    definition: str | None = Field(
        default=None,
        max_length=10_000,
        description="May be empty — add the word now, fill in the meaning later.",
        examples=["window"],
    )
    notes: str | None = Field(default=None, max_length=10_000)
    star_rating: int | None = Field(
        default=None, ge=1, le=5, description="Your own 1–5 grade for this card."
    )
    suspended: bool = False

    @field_validator("term")
    @classmethod
    def _term_not_blank(cls, value: str) -> str:
        cleaned = value.strip()
        if not cleaned:
            raise ValueError("term must not be blank")
        return cleaned

    @field_validator("definition", "notes")
    @classmethod
    def _blank_to_none(cls, value: str | None) -> str | None:
        return _clean(value)


class CardCreate(CardBase):
    tags: list[str] = Field(default_factory=list, examples=[["nouns", "de"]])
    #: Optional override, for importing cards that already have a history.
    due_at: datetime | None = None


class CardUpdate(BaseModel):
    """Every field optional — PATCH semantics. Omitted fields are untouched."""

    term: str | None = Field(default=None, min_length=1, max_length=10_000)
    definition: str | None = Field(default=None, max_length=10_000)
    notes: str | None = Field(default=None, max_length=10_000)
    star_rating: int | None = Field(default=None, ge=1, le=5)
    suspended: bool | None = None
    tags: list[str] | None = Field(
        default=None, description="Replaces the whole tag set when provided."
    )
    due_at: datetime | None = None

    @field_validator("term")
    @classmethod
    def _term_not_blank(cls, value: str | None) -> str | None:
        if value is None:
            return None
        cleaned = value.strip()
        if not cleaned:
            raise ValueError("term must not be blank")
        return cleaned


class CardOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    term: str
    definition: str | None
    notes: str | None
    tags: list[str]
    star_rating: int | None
    suspended: bool

    created_at: datetime
    updated_at: datetime
    deleted_at: datetime | None

    # --- study tracking ---
    last_shown_at: datetime | None
    first_studied_at: datetime | None
    times_shown: int
    correct_count: int
    wrong_count: int
    lapses: int
    accuracy: float | None = Field(description="correct / (correct + wrong); null if unanswered.")

    # --- scheduling ---
    srs_state: SrsState
    stability: float | None = Field(description="Days until recall probability decays to ~90%.")
    difficulty: float | None = Field(description="FSRS difficulty estimate, roughly 1–10.")
    due_at: datetime
    last_review_at: datetime | None
    retrievability: float | None = Field(
        default=None, description="Estimated chance you'd recall it right now."
    )

    audio_clips: list[AudioClipOut] = Field(default_factory=list)


class CardBulkCreate(BaseModel):
    cards: list[CardCreate] = Field(min_length=1, max_length=1000)


class BulkCreateResult(BaseModel):
    created: list[CardOut]
    skipped_duplicates: list[str] = Field(
        default_factory=list,
        description="Terms already present, skipped because skip_duplicates was set.",
    )


class SearchHit(BaseModel):
    card: CardOut
    score: float = Field(description="Trigram similarity, 0–1. Exact matches score 1.")
    matched_side: str = Field(description="Which side produced the score: term or definition.")


class SearchResponse(BaseModel):
    query: str
    #: The headline signal for "do I already have this word?" — true when a
    #: card's term or definition equals the query, ignoring case and accents.
    exact_match: bool
    hits: list[SearchHit]

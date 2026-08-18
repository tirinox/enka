from __future__ import annotations

import enum
import uuid
from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, Index, SmallInteger, func
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.types import Boolean, Float, Integer, Text

from app.db.base import Base, TimestampMixin, UUIDMixin, utcnow
from app.models.tag import card_tag

if TYPE_CHECKING:
    from app.models.audio_clip import AudioClip
    from app.models.tag import Tag


class SrsState(enum.IntEnum):
    """Mirrors ``fsrs.State`` — stored as a smallint so the numbers survive
    library changes and stay readable in raw SQL."""

    LEARNING = 1
    REVIEW = 2
    RELEARNING = 3


class Card(Base, UUIDMixin, TimestampMixin):
    __tablename__ = "card"
    __table_args__ = (
        CheckConstraint(
            "star_rating IS NULL OR (star_rating BETWEEN 1 AND 5)",
            name="star_rating_range",
        ),
        CheckConstraint("srs_state BETWEEN 1 AND 3", name="srs_state_range"),
        # The study queue: due cards, newest-owner-first, skipping the rows
        # study never wants to see.
        Index(
            "ix_card_owner_due",
            "owner_id",
            "due_at",
            postgresql_where="deleted_at IS NULL AND suspended IS false",
        ),
        # The sync cursor: "everything that changed since <watermark>".
        Index("ix_card_owner_updated_at", "owner_id", "updated_at"),
        Index("ix_card_owner_created_at", "owner_id", "created_at"),
    )

    owner_id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True), ForeignKey("owner.id", ondelete="CASCADE"), nullable=False
    )

    # --- content -----------------------------------------------------------
    term: Mapped[str] = mapped_column(Text, nullable=False)
    #: Nullable on purpose: you add words on the run and fill the meaning later.
    definition: Mapped[str | None] = mapped_column(Text, nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)

    # --- lifecycle ---------------------------------------------------------
    #: Soft delete. The row survives as a tombstone so other devices can learn
    #: about the deletion on their next delta sync; `?hard=true` purges it.
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    suspended: Mapped[bool] = mapped_column(
        Boolean, nullable=False, server_default="false", default=False
    )

    # --- display tracking --------------------------------------------------
    last_shown_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    first_studied_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    times_shown: Mapped[int] = mapped_column(Integer, nullable=False, server_default="0", default=0)

    # --- answer tallies ----------------------------------------------------
    correct_count: Mapped[int] = mapped_column(
        Integer, nullable=False, server_default="0", default=0
    )
    wrong_count: Mapped[int] = mapped_column(Integer, nullable=False, server_default="0", default=0)
    #: Times a card that had graduated to Review was forgotten again.
    lapses: Mapped[int] = mapped_column(Integer, nullable=False, server_default="0", default=0)

    # --- personal ----------------------------------------------------------
    #: Your own 1–5 star grade. Independent of the machine's `difficulty`.
    star_rating: Mapped[int | None] = mapped_column(SmallInteger, nullable=True)

    # --- FSRS scheduling state --------------------------------------------
    srs_state: Mapped[int] = mapped_column(
        SmallInteger, nullable=False, server_default="1", default=SrsState.LEARNING
    )
    #: Index into the configured learning/relearning steps; NULL once in Review.
    srs_step: Mapped[int | None] = mapped_column(Integer, nullable=True, default=0)
    #: Days until recall probability decays to ~90%. NULL until first review.
    stability: Mapped[float | None] = mapped_column(Float, nullable=True)
    #: FSRS's own 1–10 difficulty estimate — the "difficulty rating".
    difficulty: Mapped[float | None] = mapped_column(Float, nullable=True)
    #: When the card should next be shown. New cards are due immediately.
    due_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow, server_default=func.now()
    )
    last_review_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    # --- relationships -----------------------------------------------------
    tags: Mapped[list[Tag]] = relationship(
        secondary=card_tag, back_populates="cards", lazy="selectin", order_by="Tag.name_normalized"
    )
    audio_clips: Mapped[list[AudioClip]] = relationship(
        back_populates="card",
        cascade="all, delete-orphan",
        lazy="selectin",
        order_by="(AudioClip.side, AudioClip.sort_order)",
    )

    @property
    def total_answers(self) -> int:
        return self.correct_count + self.wrong_count

    @property
    def accuracy(self) -> float | None:
        total = self.total_answers
        return self.correct_count / total if total else None

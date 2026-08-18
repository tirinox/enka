from __future__ import annotations

import enum
import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Index, SmallInteger, func
from sqlalchemy import Enum as SAEnum
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column
from sqlalchemy.types import Float, Integer

from app.db.base import Base, UUIDMixin


class ReviewDirection(str, enum.Enum):
    TERM_TO_DEF = "term_to_def"
    DEF_TO_TERM = "def_to_term"


class ReviewLog(Base, UUIDMixin):
    """Append-only record of every answer.

    Three jobs: it is the raw material for stats and the activity heatmap, the
    ``prev_*`` snapshot makes undo exact rather than approximate, and it is
    exactly the dataset FSRS's optimiser needs if you later want to retrain the
    scheduler on how *you* actually remember things.
    """

    __tablename__ = "review_log"
    __table_args__ = (
        Index("ix_review_log_owner_id_reviewed_at", "owner_id", "reviewed_at"),
        Index("ix_review_log_card_id_reviewed_at", "card_id", "reviewed_at"),
    )

    owner_id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True), ForeignKey("owner.id", ondelete="CASCADE"), nullable=False
    )
    card_id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True), ForeignKey("card.id", ondelete="CASCADE"), nullable=False
    )

    reviewed_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    #: 1 again / 2 hard / 3 good / 4 easy — matches ``fsrs.Rating``.
    rating: Mapped[int] = mapped_column(SmallInteger, nullable=False)
    direction: Mapped[ReviewDirection | None] = mapped_column(
        SAEnum(
            ReviewDirection,
            name="review_direction",
            values_callable=lambda e: [m.value for m in e],
        ),
        nullable=True,
    )
    #: How long you looked at the card before answering, if the client reports it.
    elapsed_ms: Mapped[int | None] = mapped_column(Integer, nullable=True)

    # --- snapshot before this review (for undo + analysis) -----------------
    prev_state: Mapped[int | None] = mapped_column(SmallInteger, nullable=True)
    prev_step: Mapped[int | None] = mapped_column(Integer, nullable=True)
    prev_stability: Mapped[float | None] = mapped_column(Float, nullable=True)
    prev_difficulty: Mapped[float | None] = mapped_column(Float, nullable=True)
    prev_due_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    prev_last_review_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    # --- snapshot after ----------------------------------------------------
    new_state: Mapped[int | None] = mapped_column(SmallInteger, nullable=True)
    new_stability: Mapped[float | None] = mapped_column(Float, nullable=True)
    new_difficulty: Mapped[float | None] = mapped_column(Float, nullable=True)
    new_due_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    #: Undo marks rather than deletes, so the history stays honest.
    undone_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

from __future__ import annotations

import enum
import uuid
from typing import TYPE_CHECKING

from sqlalchemy import Enum as SAEnum
from sqlalchemy import ForeignKey, Index
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.types import BigInteger, Integer, String

from app.db.base import Base, TimestampMixin, UUIDMixin

if TYPE_CHECKING:
    from app.models.card import Card


class AudioSide(str, enum.Enum):
    """Which half of the card a clip belongs to — the native speaker saying
    the term, or the same for the definition."""

    TERM = "term"
    DEFINITION = "definition"


class AudioClip(Base, UUIDMixin, TimestampMixin):
    __tablename__ = "audio_clip"
    __table_args__ = (
        Index("ix_audio_clip_card_id_side", "card_id", "side"),
        Index("ix_audio_clip_owner_id", "owner_id"),
    )

    owner_id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True), ForeignKey("owner.id", ondelete="CASCADE"), nullable=False
    )
    card_id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True), ForeignKey("card.id", ondelete="CASCADE"), nullable=False
    )
    side: Mapped[AudioSide] = mapped_column(
        SAEnum(AudioSide, name="audio_side", values_callable=lambda e: [m.value for m in e]),
        nullable=False,
    )

    #: Path relative to ENKA_AUDIO_DIR. Relative so the volume can be moved,
    #: and so swapping in an S3 backend is a key-prefix change, nothing more.
    storage_key: Mapped[str] = mapped_column(String(512), nullable=False)
    original_filename: Mapped[str | None] = mapped_column(String(255), nullable=True)
    content_type: Mapped[str] = mapped_column(String(100), nullable=False)
    size_bytes: Mapped[int] = mapped_column(BigInteger, nullable=False)
    #: Content hash — doubles as the HTTP ETag and lets clients skip re-downloads.
    sha256: Mapped[str] = mapped_column(String(64), nullable=False)
    duration_ms: Mapped[int | None] = mapped_column(Integer, nullable=True)
    sort_order: Mapped[int] = mapped_column(Integer, nullable=False, server_default="0", default=0)

    card: Mapped[Card] = relationship(back_populates="audio_clips")

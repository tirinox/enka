from __future__ import annotations

import uuid
from typing import TYPE_CHECKING

from sqlalchemy import Column, ForeignKey, Index, Table, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.types import String

from app.db.base import Base, TimestampMixin, UUIDMixin

if TYPE_CHECKING:
    from app.models.card import Card

card_tag = Table(
    "card_tag",
    Base.metadata,
    Column(
        "card_id",
        PGUUID(as_uuid=True),
        ForeignKey("card.id", ondelete="CASCADE"),
        primary_key=True,
    ),
    Column(
        "tag_id",
        PGUUID(as_uuid=True),
        ForeignKey("tag.id", ondelete="CASCADE"),
        primary_key=True,
    ),
    Index("ix_card_tag_tag_id", "tag_id"),
)


class Tag(Base, UUIDMixin, TimestampMixin):
    """Free-form label. With no decks in the model, tags carry all the
    organisation: language, part of speech, source, difficulty — whatever you
    want to scope study, search and stats by."""

    __tablename__ = "tag"
    __table_args__ = (
        # Case-insensitive uniqueness: "Verbs" and "verbs" must not coexist.
        UniqueConstraint("owner_id", "name_normalized", name="uq_tag_owner_id_name_normalized"),
        Index("ix_tag_owner_id", "owner_id"),
    )

    owner_id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True), ForeignKey("owner.id", ondelete="CASCADE"), nullable=False
    )
    name: Mapped[str] = mapped_column(String(64), nullable=False)
    #: ``lower(trim(name))`` — kept as a real column so it can be uniquely
    #: indexed and matched without a functional index on every query.
    name_normalized: Mapped[str] = mapped_column(String(64), nullable=False)
    color: Mapped[str | None] = mapped_column(String(16), nullable=True)

    cards: Mapped[list[Card]] = relationship(
        secondary=card_tag, back_populates="tags", lazy="noload"
    )

    @staticmethod
    def normalize(name: str) -> str:
        return " ".join(name.split()).lower()

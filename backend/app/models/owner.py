from __future__ import annotations

from sqlalchemy.orm import Mapped, mapped_column
from sqlalchemy.types import String

from app.db.base import Base, TimestampMixin, UUIDMixin


class Owner(Base, UUIDMixin, TimestampMixin):
    """The person this instance belongs to.

    There is exactly one row today, seeded at startup. It exists so that every
    other table can carry ``owner_id`` from day one: turning Enka multi-user
    later becomes a change to how tokens are issued, not a migration that has
    to backfill ownership across thousands of cards.
    """

    __tablename__ = "owner"

    name: Mapped[str] = mapped_column(String(120), nullable=False, default="me")

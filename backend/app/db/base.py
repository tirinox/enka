from __future__ import annotations

import uuid
from datetime import UTC, datetime

from sqlalchemy import DateTime, MetaData, func
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


def utcnow() -> datetime:
    """The single clock for the whole application.

    Timestamps are generated here rather than by Postgres' ``now()`` for two
    reasons. First, ``now()`` is the *transaction* start time, so several rows
    written in one request would share a timestamp. Second — and this is the
    one that bites — a server-side ``onupdate`` forces SQLAlchemy to expire the
    attribute after every UPDATE and re-read it lazily, which raises
    MissingGreenlet under asyncio. Generating them in Python also keeps
    ``updated_at`` on exactly the same clock as the ``server_time`` watermark
    handed to sync clients.
    """
    return datetime.now(UTC)


# Predictable constraint names, so Alembic autogenerate produces stable,
# reversible migrations instead of Postgres-invented identifiers.
NAMING_CONVENTION = {
    "ix": "ix_%(table_name)s_%(column_0_N_name)s",
    "uq": "uq_%(table_name)s_%(column_0_N_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_N_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}


class Base(DeclarativeBase):
    metadata = MetaData(naming_convention=NAMING_CONVENTION)


class UUIDMixin:
    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)


class TimestampMixin:
    """``created_at`` doubles as 'date added'; ``updated_at`` is the sync watermark.

    Both are set by the database (``now()``) rather than by Python, so a client
    with a wrong clock can never poison the ordering that delta sync relies on.
    """

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=utcnow,
        onupdate=utcnow,
        server_default=func.now(),
        nullable=False,
    )

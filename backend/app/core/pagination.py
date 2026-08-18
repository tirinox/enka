from __future__ import annotations

from datetime import UTC, datetime
from typing import Generic, TypeVar

from pydantic import BaseModel, Field

T = TypeVar("T")


class Page(BaseModel, Generic[T]):
    """Offset-paginated envelope.

    ``server_time`` is the server's clock at query time. Clients store it and
    pass it back as ``updated_since`` on the next sync, which keeps delta
    fetches immune to clock skew between the device and the server.
    """

    items: list[T]
    total: int = Field(description="Total rows matching the filters, ignoring limit/offset.")
    limit: int
    offset: int
    has_more: bool
    server_time: datetime = Field(default_factory=lambda: datetime.now(UTC))

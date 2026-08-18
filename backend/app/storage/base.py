"""Storage seam.

Audio lives on a Docker volume today. Everything above this module speaks only
in opaque ``storage_key`` strings, so moving to S3/MinIO later means writing one
more implementation of this protocol — no API, schema or router changes.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from dataclasses import dataclass
from typing import Protocol, runtime_checkable


@dataclass(frozen=True)
class StoredObject:
    key: str
    size_bytes: int
    sha256: str


@runtime_checkable
class Storage(Protocol):
    async def save(self, key: str, chunks: AsyncIterator[bytes], *, max_bytes: int) -> StoredObject:
        """Persist a stream, aborting once ``max_bytes`` is exceeded."""

    def stream(self, key: str, *, start: int = 0, end: int | None = None) -> AsyncIterator[bytes]:
        """Yield bytes of ``key`` in ``[start, end]`` inclusive, for HTTP Range."""

    async def size(self, key: str) -> int: ...

    async def exists(self, key: str) -> bool: ...

    async def delete(self, key: str) -> None: ...

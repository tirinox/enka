from __future__ import annotations

import asyncio
import contextlib
import hashlib
import os
from collections.abc import AsyncIterator
from pathlib import Path

import aiofiles

from app.core.errors import NotFoundError, PayloadTooLargeError
from app.storage.base import StoredObject

CHUNK_SIZE = 64 * 1024


class LocalStorage:
    """Files on a mounted volume, addressed by relative key."""

    def __init__(self, root: str | Path) -> None:
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)

    def _path(self, key: str) -> Path:
        # Resolve and re-check containment: a key is never user-supplied today,
        # but this is the one place where a traversal bug would let a request
        # read or clobber arbitrary files.
        candidate = (self.root / key).resolve()
        root = self.root.resolve()
        if not candidate.is_relative_to(root):
            raise NotFoundError("Invalid storage key.")
        return candidate

    async def save(self, key: str, chunks: AsyncIterator[bytes], *, max_bytes: int) -> StoredObject:
        path = self._path(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        digest = hashlib.sha256()
        size = 0
        try:
            async with aiofiles.open(path, "wb") as fh:
                async for chunk in chunks:
                    size += len(chunk)
                    if size > max_bytes:
                        raise PayloadTooLargeError(
                            f"File exceeds the {max_bytes // (1024 * 1024)} MB limit.",
                            {"max_bytes": max_bytes},
                        )
                    digest.update(chunk)
                    await fh.write(chunk)
        except BaseException:
            # Never leave a partial file behind for a request that failed.
            await self.delete(key)
            raise
        return StoredObject(key=key, size_bytes=size, sha256=digest.hexdigest())

    async def stream(
        self, key: str, *, start: int = 0, end: int | None = None
    ) -> AsyncIterator[bytes]:
        path = self._path(key)
        if not path.is_file():
            raise NotFoundError("Audio file is missing from storage.")
        remaining = None if end is None else (end - start + 1)
        async with aiofiles.open(path, "rb") as fh:
            await fh.seek(start)
            while remaining is None or remaining > 0:
                to_read = CHUNK_SIZE if remaining is None else min(CHUNK_SIZE, remaining)
                chunk = await fh.read(to_read)
                if not chunk:
                    break
                if remaining is not None:
                    remaining -= len(chunk)
                yield chunk

    async def size(self, key: str) -> int:
        path = self._path(key)
        try:
            return (await asyncio.to_thread(os.stat, path)).st_size
        except OSError as exc:
            raise NotFoundError("Audio file is missing from storage.") from exc

    async def exists(self, key: str) -> bool:
        return await asyncio.to_thread(self._path(key).is_file)

    async def delete(self, key: str) -> None:
        path = self._path(key)

        def _remove() -> None:
            path.unlink(missing_ok=True)
            # Tidy up the now-empty per-card directory; harmless if it isn't.
            with contextlib.suppress(OSError):
                path.parent.rmdir()

        await asyncio.to_thread(_remove)

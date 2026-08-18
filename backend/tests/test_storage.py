"""Unit tests for the local storage backend."""

from __future__ import annotations

import hashlib
from collections.abc import AsyncIterator

import pytest

from app.core.errors import NotFoundError, PayloadTooLargeError
from app.storage.local import LocalStorage


async def chunks_of(*payloads: bytes) -> AsyncIterator[bytes]:
    for payload in payloads:
        yield payload


@pytest.fixture
def storage(tmp_path) -> LocalStorage:
    return LocalStorage(tmp_path / "audio")


async def test_save_reports_size_and_hash(storage):
    data = b"hello audio world"
    stored = await storage.save("card/clip.wav", chunks_of(data), max_bytes=1024)

    assert stored.size_bytes == len(data)
    assert stored.sha256 == hashlib.sha256(data).hexdigest()
    assert await storage.exists("card/clip.wav")


async def test_save_reassembles_a_chunked_stream(storage):
    await storage.save("k", chunks_of(b"abc", b"def", b"ghi"), max_bytes=1024)
    assert await _read_all(storage, "k") == b"abcdefghi"


async def test_save_aborts_and_cleans_up_when_too_large(storage):
    with pytest.raises(PayloadTooLargeError):
        await storage.save("k", chunks_of(b"x" * 100), max_bytes=10)
    assert not await storage.exists("k")


async def test_size_limit_is_enforced_mid_stream(storage):
    """A single huge chunk isn't the only case — the running total matters."""
    with pytest.raises(PayloadTooLargeError):
        await storage.save("k", chunks_of(*[b"x" * 10] * 20), max_bytes=50)
    assert not await storage.exists("k")


async def test_a_failing_stream_leaves_no_partial_file(storage):
    async def exploding() -> AsyncIterator[bytes]:
        yield b"partial data"
        raise RuntimeError("upload connection dropped")

    with pytest.raises(RuntimeError):
        await storage.save("k", exploding(), max_bytes=1024)
    assert not await storage.exists("k")


@pytest.mark.parametrize(
    "key", ["../escape.wav", "a/../../escape.wav", "/etc/passwd", "a/../../../etc/passwd"]
)
async def test_keys_cannot_escape_the_storage_root(storage, key):
    with pytest.raises(NotFoundError):
        await storage.save(key, chunks_of(b"data"), max_bytes=1024)


async def test_stream_returns_the_whole_file_by_default(storage):
    await storage.save("k", chunks_of(b"0123456789"), max_bytes=1024)
    assert await _read_all(storage, "k") == b"0123456789"


@pytest.mark.parametrize(
    ("start", "end", "expected"),
    [(0, 4, b"01234"), (5, 9, b"56789"), (3, 3, b"3"), (7, None, b"789")],
)
async def test_stream_honours_an_inclusive_range(storage, start, end, expected):
    await storage.save("k", chunks_of(b"0123456789"), max_bytes=1024)

    collected = b""
    async for chunk in storage.stream("k", start=start, end=end):
        collected += chunk
    assert collected == expected


async def test_streaming_a_missing_key_raises(storage):
    with pytest.raises(NotFoundError):
        await _read_all(storage, "nope")


async def test_size_of_a_missing_key_raises(storage):
    with pytest.raises(NotFoundError):
        await storage.size("nope")


async def test_delete_is_idempotent(storage):
    await storage.save("k", chunks_of(b"data"), max_bytes=1024)
    await storage.delete("k")
    await storage.delete("k")  # must not raise
    assert not await storage.exists("k")


async def test_delete_tidies_the_empty_parent_directory(storage):
    await storage.save("card-id/clip.wav", chunks_of(b"data"), max_bytes=1024)
    await storage.delete("card-id/clip.wav")
    assert not (storage.root / "card-id").exists()


async def test_delete_keeps_a_directory_that_still_has_files(storage):
    await storage.save("card-id/one.wav", chunks_of(b"a"), max_bytes=1024)
    await storage.save("card-id/two.wav", chunks_of(b"b"), max_bytes=1024)
    await storage.delete("card-id/one.wav")

    assert (storage.root / "card-id").exists()
    assert await storage.exists("card-id/two.wav")


async def _read_all(storage: LocalStorage, key: str) -> bytes:
    collected = b""
    async for chunk in storage.stream(key):
        collected += chunk
    return collected

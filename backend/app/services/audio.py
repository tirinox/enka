"""Audio validation and ingest.

Content-type from the client is a hint, not evidence — browsers and mobile
recorders routinely send ``application/octet-stream``. We sniff the leading
bytes instead and store the type we actually detected.
"""

from __future__ import annotations

import uuid
from collections.abc import AsyncIterator

from fastapi import UploadFile

from app.core.config import settings
from app.core.errors import UnsupportedMediaTypeError
from app.models.audio_clip import AudioSide
from app.storage.base import Storage, StoredObject

#: Detected format -> (mime type, file extension).
FORMATS: dict[str, tuple[str, str]] = {
    "mp3": ("audio/mpeg", "mp3"),
    "m4a": ("audio/mp4", "m4a"),
    "ogg": ("audio/ogg", "ogg"),
    "wav": ("audio/wav", "wav"),
    "flac": ("audio/flac", "flac"),
    "webm": ("audio/webm", "webm"),
}

#: Enough bytes to cover an ID3 tag plus an ftyp box.
SNIFF_BYTES = 64


def sniff_format(head: bytes) -> str | None:
    if len(head) < 4:
        return None
    if head[:3] == b"ID3" or (head[0] == 0xFF and (head[1] & 0xE0) == 0xE0):
        return "mp3"
    if head[:4] == b"OggS":
        return "ogg"
    if head[:4] == b"fLaC":
        return "flac"
    if head[:4] == b"RIFF" and head[8:12] == b"WAVE":
        return "wav"
    if head[:4] == b"\x1a\x45\xdf\xa3":
        # Matroska container; WebM audio is by far the likeliest source here
        # (it is what MediaRecorder produces in the browser).
        return "webm"
    if head[4:8] == b"ftyp":
        brand = head[8:12]
        if brand[:3] in (b"M4A", b"M4B", b"mp4") or brand in (b"isom", b"iso2", b"mp42", b"dash"):
            return "m4a"
    return None


class RejectedUpload(UnsupportedMediaTypeError):
    pass


async def ingest_upload(
    storage: Storage,
    upload: UploadFile,
    *,
    card_id: uuid.UUID,
    clip_id: uuid.UUID,
    side: AudioSide,
) -> tuple[StoredObject, str, str]:
    """Validate and persist an uploaded clip.

    Returns ``(stored, content_type, storage_key)``.
    """
    head = await upload.read(SNIFF_BYTES)
    if not head:
        raise RejectedUpload("Uploaded file is empty.")

    fmt = sniff_format(head)
    if fmt is None:
        raise RejectedUpload(
            "That doesn't look like an audio file. Accepted: mp3, m4a, ogg/opus, wav, flac, webm.",
            {
                "declared_content_type": upload.content_type,
                "accepted": sorted(FORMATS),
            },
        )

    content_type, extension = FORMATS[fmt]
    storage_key = f"{card_id}/{clip_id}.{extension}"

    async def chunks() -> AsyncIterator[bytes]:
        # The sniffed head was consumed from the stream; put it back first.
        yield head
        while chunk := await upload.read(1024 * 1024):
            yield chunk

    stored = await storage.save(storage_key, chunks(), max_bytes=settings.max_audio_bytes)
    if stored.size_bytes == 0:
        await storage.delete(storage_key)
        raise RejectedUpload("Uploaded file is empty.")
    return stored, content_type, storage_key


def parse_range_header(value: str | None, size: int) -> tuple[int, int] | None:
    """Parse a single-range ``bytes=`` header into an inclusive ``(start, end)``.

    Returns ``None`` when there is no range to honour. Raises ValueError when
    the header is present but unsatisfiable, which the router turns into a 416.
    """
    if not value or not value.startswith("bytes="):
        return None
    spec = value[len("bytes=") :].split(",", 1)[0].strip()
    if "-" not in spec:
        raise ValueError("malformed range")
    raw_start, _, raw_end = spec.partition("-")

    if not raw_start:
        # Suffix form: "bytes=-500" means the last 500 bytes.
        if not raw_end:
            raise ValueError("malformed range")
        length = int(raw_end)
        if length <= 0:
            raise ValueError("malformed range")
        start = max(0, size - length)
        return start, size - 1

    start = int(raw_start)
    end = int(raw_end) if raw_end else size - 1
    if start >= size or end < start:
        raise ValueError("unsatisfiable range")
    return start, min(end, size - 1)

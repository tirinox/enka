from __future__ import annotations

import uuid

import pytest

from app.core.security import create_token
from app.services.audio import parse_range_header, sniff_format


# ------------------------------------------------------------ format sniff --
@pytest.mark.parametrize(
    ("head", "expected"),
    [
        (b"ID3\x03\x00\x00\x00\x00\x00\x00", "mp3"),
        (b"\xff\xfb\x90\x00", "mp3"),
        (b"OggS\x00\x02\x00\x00", "ogg"),
        (b"fLaC\x00\x00\x00\x22", "flac"),
        (b"RIFF\x24\x00\x00\x00WAVEfmt ", "wav"),
        (b"\x1a\x45\xdf\xa3\x00\x00\x00\x00", "webm"),
        (b"\x00\x00\x00\x20ftypM4A \x00\x00", "m4a"),
        (b"\x00\x00\x00\x18ftypmp42\x00\x00", "m4a"),
    ],
)
def test_sniff_recognises_real_audio_headers(head, expected):
    assert sniff_format(head) == expected


@pytest.mark.parametrize(
    "head",
    [
        b"",
        b"\x89PNG\r\n\x1a\n",
        b"%PDF-1.7\n",
        b"#!/bin/sh\nrm -rf /\n",
        b"RIFF\x24\x00\x00\x00AVI LIST",  # RIFF, but not WAVE
    ],
)
def test_sniff_rejects_everything_else(head):
    assert sniff_format(head) is None


# ------------------------------------------------------------ range header --
@pytest.mark.parametrize(
    ("header", "size", "expected"),
    [
        (None, 1000, None),
        ("", 1000, None),
        ("bytes=0-99", 1000, (0, 99)),
        ("bytes=100-", 1000, (100, 999)),
        ("bytes=-200", 1000, (800, 999)),
        ("bytes=0-100000", 1000, (0, 999)),  # clamped to the file
        ("bytes=0-99, 200-299", 1000, (0, 99)),  # only the first range
        ("items=0-99", 1000, None),  # unsupported unit is ignored
    ],
)
def test_range_header_parsing(header, size, expected):
    assert parse_range_header(header, size) == expected


@pytest.mark.parametrize("header", ["bytes=2000-", "bytes=500-100", "bytes=abc", "bytes="])
def test_unsatisfiable_ranges_raise(header):
    with pytest.raises(ValueError):
        parse_range_header(header, 1000)


# ---------------------------------------------------------------- uploads ---
async def test_upload_and_download_round_trip(client, card_factory, wav_bytes):
    card = await card_factory("das Fenster", "window")

    upload = await client.post(
        f"/api/v1/cards/{card['id']}/audio?side=term",
        files={"file": ("fenster.wav", wav_bytes, "audio/wav")},
    )
    assert upload.status_code == 201, upload.text
    clip = upload.json()
    assert clip["content_type"] == "audio/wav"
    assert clip["size_bytes"] == len(wav_bytes)
    assert clip["side"] == "term"
    assert clip["url"] == f"/api/v1/audio/{clip['id']}"

    download = await client.get(f"/api/v1/audio/{clip['id']}")
    assert download.status_code == 200
    assert download.content == wav_bytes
    assert download.headers["accept-ranges"] == "bytes"
    assert download.headers["etag"].strip('"') == clip["sha256"]


async def test_content_type_comes_from_the_bytes_not_the_client(client, card_factory, wav_bytes):
    """A browser sending application/octet-stream must still work."""
    card = await card_factory("word")
    upload = await client.post(
        f"/api/v1/cards/{card['id']}/audio?side=term",
        files={"file": ("recording.bin", wav_bytes, "application/octet-stream")},
    )
    assert upload.status_code == 201
    assert upload.json()["content_type"] == "audio/wav"


async def test_a_renamed_non_audio_file_is_rejected(client, card_factory):
    """Trusting the extension or the declared type would let this through."""
    card = await card_factory("word")
    upload = await client.post(
        f"/api/v1/cards/{card['id']}/audio?side=term",
        files={"file": ("evil.mp3", b"\x89PNG\r\n\x1a\n" + b"\x00" * 100, "audio/mpeg")},
    )
    assert upload.status_code == 415
    assert upload.json()["error"]["code"] == "unsupported_media_type"


async def test_empty_upload_is_rejected(client, card_factory):
    card = await card_factory("word")
    upload = await client.post(
        f"/api/v1/cards/{card['id']}/audio?side=term",
        files={"file": ("silence.wav", b"", "audio/wav")},
    )
    assert upload.status_code == 415


async def test_oversized_upload_is_rejected(client, card_factory, wav_bytes):
    """max_audio_mb is set to 1 in the test settings."""
    card = await card_factory("word")
    oversized = wav_bytes + b"\x00" * (2 * 1024 * 1024)

    upload = await client.post(
        f"/api/v1/cards/{card['id']}/audio?side=term",
        files={"file": ("big.wav", oversized, "audio/wav")},
    )
    assert upload.status_code == 413
    assert upload.json()["error"]["code"] == "payload_too_large"


async def test_rejected_upload_leaves_no_file_behind(client, card_factory, wav_bytes):
    card = await card_factory("word")
    oversized = wav_bytes + b"\x00" * (2 * 1024 * 1024)
    await client.post(
        f"/api/v1/cards/{card['id']}/audio?side=term",
        files={"file": ("big.wav", oversized, "audio/wav")},
    )

    root = client.storage.root
    leftovers = [p for p in root.rglob("*") if p.is_file()] if root.exists() else []
    assert leftovers == []


async def test_both_sides_can_carry_audio(client, card_factory, wav_bytes, mp3_bytes):
    card = await card_factory("das Fenster", "window")

    await client.post(
        f"/api/v1/cards/{card['id']}/audio?side=term",
        files={"file": ("term.wav", wav_bytes, "audio/wav")},
    )
    await client.post(
        f"/api/v1/cards/{card['id']}/audio?side=definition",
        files={"file": ("def.mp3", mp3_bytes, "audio/mpeg")},
    )

    clips = (await client.get(f"/api/v1/cards/{card['id']}/audio")).json()
    assert {c["side"] for c in clips} == {"term", "definition"}

    term_only = (await client.get(f"/api/v1/cards/{card['id']}/audio?side=term")).json()
    assert len(term_only) == 1


async def test_multiple_clips_per_side_are_ordered(client, card_factory, wav_bytes):
    card = await card_factory("word")
    for _ in range(3):
        await client.post(
            f"/api/v1/cards/{card['id']}/audio?side=term",
            files={"file": ("a.wav", wav_bytes, "audio/wav")},
        )

    clips = (await client.get(f"/api/v1/cards/{card['id']}/audio")).json()
    assert [c["sort_order"] for c in clips] == [0, 1, 2]


async def test_card_response_embeds_its_clips(client, card_factory, wav_bytes):
    card = await card_factory("word")
    await client.post(
        f"/api/v1/cards/{card['id']}/audio?side=term",
        files={"file": ("a.wav", wav_bytes, "audio/wav")},
    )

    fetched = (await client.get(f"/api/v1/cards/{card['id']}")).json()
    assert len(fetched["audio_clips"]) == 1


async def test_uploading_to_an_unknown_card_is_404(client, wav_bytes):
    upload = await client.post(
        f"/api/v1/cards/{uuid.uuid4()}/audio?side=term",
        files={"file": ("a.wav", wav_bytes, "audio/wav")},
    )
    assert upload.status_code == 404


# ----------------------------------------------------------------- ranges ---
async def test_range_request_returns_partial_content(client, card_factory, wav_bytes):
    card = await card_factory("word")
    clip = (
        await client.post(
            f"/api/v1/cards/{card['id']}/audio?side=term",
            files={"file": ("a.wav", wav_bytes, "audio/wav")},
        )
    ).json()

    response = await client.get(f"/api/v1/audio/{clip['id']}", headers={"Range": "bytes=0-99"})
    assert response.status_code == 206
    assert response.content == wav_bytes[:100]
    assert response.headers["content-range"] == f"bytes 0-99/{len(wav_bytes)}"
    assert response.headers["content-length"] == "100"


async def test_suffix_range_returns_the_tail(client, card_factory, wav_bytes):
    card = await card_factory("word")
    clip = (
        await client.post(
            f"/api/v1/cards/{card['id']}/audio?side=term",
            files={"file": ("a.wav", wav_bytes, "audio/wav")},
        )
    ).json()

    response = await client.get(f"/api/v1/audio/{clip['id']}", headers={"Range": "bytes=-50"})
    assert response.status_code == 206
    assert response.content == wav_bytes[-50:]


async def test_unsatisfiable_range_is_416(client, card_factory, wav_bytes):
    card = await card_factory("word")
    clip = (
        await client.post(
            f"/api/v1/cards/{card['id']}/audio?side=term",
            files={"file": ("a.wav", wav_bytes, "audio/wav")},
        )
    ).json()

    response = await client.get(f"/api/v1/audio/{clip['id']}", headers={"Range": "bytes=999999-"})
    assert response.status_code == 416


# ------------------------------------------------------------------- auth ---
async def test_audio_requires_authentication(anon_client, force_owner, wav_bytes):
    card = (await anon_client.post("/api/v1/cards", json={"term": "word"})).json()
    clip = (
        await anon_client.post(
            f"/api/v1/cards/{card['id']}/audio?side=term",
            files={"file": ("a.wav", wav_bytes, "audio/wav")},
        )
    ).json()

    from app.api.deps import get_current_owner
    from app.main import app

    app.dependency_overrides.pop(get_current_owner, None)
    response = await anon_client.get(f"/api/v1/audio/{clip['id']}")
    assert response.status_code == 401


async def test_media_token_in_the_query_string_works(client, owner, card_factory, wav_bytes):
    """So a browser `<audio src>` can play it without setting headers."""
    card = await card_factory("word")
    clip = (
        await client.post(
            f"/api/v1/cards/{card['id']}/audio?side=term",
            files={"file": ("a.wav", wav_bytes, "audio/wav")},
        )
    ).json()

    media_token, _ = create_token(owner.id, scope="media")
    del client.headers["Authorization"]

    response = await client.get(f"/api/v1/audio/{clip['id']}?token={media_token}")
    assert response.status_code == 200
    assert response.content == wav_bytes


# --------------------------------------------------------------- deletion ---
async def test_deleting_a_clip_removes_the_file(client, card_factory, wav_bytes):
    card = await card_factory("word")
    clip = (
        await client.post(
            f"/api/v1/cards/{card['id']}/audio?side=term",
            files={"file": ("a.wav", wav_bytes, "audio/wav")},
        )
    ).json()

    assert (await client.delete(f"/api/v1/audio/{clip['id']}")).status_code == 204
    assert (await client.get(f"/api/v1/audio/{clip['id']}")).status_code == 404

    leftovers = [p for p in client.storage.root.rglob("*") if p.is_file()]
    assert leftovers == []


async def test_hard_deleting_a_card_removes_its_audio(client, card_factory, wav_bytes):
    card = await card_factory("word")
    await client.post(
        f"/api/v1/cards/{card['id']}/audio?side=term",
        files={"file": ("a.wav", wav_bytes, "audio/wav")},
    )

    await client.delete(f"/api/v1/cards/{card['id']}?hard=true")

    leftovers = [p for p in client.storage.root.rglob("*") if p.is_file()]
    assert leftovers == []


async def test_clip_metadata_can_be_updated(client, card_factory, wav_bytes):
    card = await card_factory("word")
    clip = (
        await client.post(
            f"/api/v1/cards/{card['id']}/audio?side=term",
            files={"file": ("a.wav", wav_bytes, "audio/wav")},
        )
    ).json()

    response = await client.patch(
        f"/api/v1/audio/{clip['id']}", json={"duration_ms": 1234, "sort_order": 7}
    )
    assert response.status_code == 200
    assert response.json()["duration_ms"] == 1234
    assert response.json()["sort_order"] == 7

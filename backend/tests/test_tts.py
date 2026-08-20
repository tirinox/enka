"""TTS: language detection, and auto-generated term audio on card creation.

Real Piper inference needs voice model files this repo doesn't ship, so every
test that exercises the orchestration replaces the two Piper touchpoints
(`_load_voice`, `_synthesize_wav_bytes`) with fakes via the `stub_piper`
fixture (conftest.py — shared with test_backfill_term_audio.py).
`test_missing_voice_model_file_skips_clip_generation` is the exception — it
runs the real `_load_voice` against an empty directory, to prove the "no
model file" path is exercised without needing real model bytes.
"""

from __future__ import annotations

import pytest

from app.core.config import settings
from app.services import tts as tts_service


# ------------------------------------------------------------ detection ----
@pytest.mark.parametrize(
    ("term", "expected"),
    [
        ("hello", "en"),
        ("window", "en"),
        ("beautiful", "en"),
        ("спасибо", "ru"),
        ("привет", "ru"),
        ("слово", "ru"),
    ],
)
def test_detect_language_picks_the_right_configured_language(term, expected):
    assert tts_service.detect_language(term) == expected


def test_detect_language_blank_text_is_none():
    assert tts_service.detect_language("   ") is None


def test_detect_language_no_configured_voices_is_none(monkeypatch):
    monkeypatch.setattr(settings, "tts_voice_map", {})
    assert tts_service.detect_language("hello") is None


def test_detect_language_respects_the_confidence_floor(monkeypatch):
    monkeypatch.setattr(settings, "tts_min_confidence", 1.01)  # unreachable
    assert tts_service.detect_language("hello") is None


# --------------------------------------------------------- orchestration ---
async def test_tts_is_off_by_default(client):
    """Everything else in the suite relies on this."""
    response = await client.post("/api/v1/cards", json={"term": "hello"})
    card_id = response.json()["id"]
    fetched = (await client.get(f"/api/v1/cards/{card_id}")).json()
    assert fetched["audio_clips"] == []


async def test_card_creation_generates_a_term_clip(client, stub_piper, wav_bytes):
    """The clip lands after the response — the create response itself is
    built before the background task runs, so it never carries the clip."""
    response = await client.post("/api/v1/cards", json={"term": "hello", "definition": "привет"})
    assert response.status_code == 201
    assert response.json()["audio_clips"] == []

    fetched = (await client.get(f"/api/v1/cards/{response.json()['id']}")).json()
    assert len(fetched["audio_clips"]) == 1
    clip = fetched["audio_clips"][0]
    assert clip["side"] == "term"
    assert clip["content_type"] == "audio/wav"
    assert clip["size_bytes"] == len(wav_bytes)

    download = await client.get(f"/api/v1/audio/{clip['id']}")
    assert download.status_code == 200
    assert download.content == wav_bytes


async def test_only_the_term_gets_a_clip_not_the_definition(client, stub_piper):
    response = await client.post(
        "/api/v1/cards", json={"term": "hello", "definition": "a whole sentence here"}
    )
    fetched = (await client.get(f"/api/v1/cards/{response.json()['id']}")).json()
    assert {c["side"] for c in fetched["audio_clips"]} == {"term"}


async def test_bulk_create_generates_a_clip_per_card(client, stub_piper):
    response = await client.post(
        "/api/v1/cards/bulk",
        json={"cards": [{"term": "hello"}, {"term": "спасибо"}]},
    )
    assert response.status_code == 201
    for created in response.json()["created"]:
        fetched = (await client.get(f"/api/v1/cards/{created['id']}")).json()
        assert len(fetched["audio_clips"]) == 1


async def test_synthesis_failure_does_not_fail_card_creation(client, monkeypatch):
    def boom(lang: str):
        raise RuntimeError("synthesis blew up")

    monkeypatch.setattr(settings, "tts_enabled", True)
    monkeypatch.setattr(tts_service, "_load_voice", boom)

    response = await client.post("/api/v1/cards", json={"term": "hello"})
    assert response.status_code == 201
    fetched = (await client.get(f"/api/v1/cards/{response.json()['id']}")).json()
    assert fetched["audio_clips"] == []


async def test_missing_voice_model_file_skips_clip_generation(client, monkeypatch, tmp_path):
    """Exercises the real `_load_voice` against a directory with no model files."""
    monkeypatch.setattr(settings, "tts_enabled", True)
    monkeypatch.setattr(settings, "tts_model_dir", str(tmp_path))

    response = await client.post("/api/v1/cards", json={"term": "hello"})
    assert response.status_code == 201
    fetched = (await client.get(f"/api/v1/cards/{response.json()['id']}")).json()
    assert fetched["audio_clips"] == []

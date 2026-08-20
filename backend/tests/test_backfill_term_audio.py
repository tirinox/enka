"""app/scripts/backfill_term_audio.py — the query and the orchestration loop.

Cards are created over HTTP with TTS off (the suite-wide default), so every
card `card_factory` makes starts out missing term audio for free. The CLI
shell (`main`/`_run_cli`) isn't exercised here — it's just argument parsing
and a real `SessionLocal()`/`print()`; the interesting logic is the query and
`backfill()`, both of which take an already-open session/storage.
"""

from __future__ import annotations

import uuid

from app.models.audio_clip import AudioSide
from app.scripts import backfill_term_audio as script


async def test_finds_only_cards_missing_a_term_clip(db, client, card_factory, wav_bytes):
    has_audio = await card_factory("hello")
    missing_audio = await card_factory("window")

    await client.post(
        f"/api/v1/cards/{has_audio['id']}/audio?side=term",
        files={"file": ("a.wav", wav_bytes, "audio/wav")},
    )

    found = await script.find_cards_missing_term_audio(db)
    assert [c.id for c in found] == [uuid.UUID(missing_audio["id"])]


async def test_a_definition_side_clip_does_not_count_as_term_audio(
    db, client, card_factory, wav_bytes
):
    card = await card_factory("hello", "definition text")
    await client.post(
        f"/api/v1/cards/{card['id']}/audio?side=definition",
        files={"file": ("a.wav", wav_bytes, "audio/wav")},
    )

    found = await script.find_cards_missing_term_audio(db)
    assert [str(c.id) for c in found] == [card["id"]]


async def test_soft_deleted_cards_are_excluded(db, client, card_factory):
    card = await card_factory("hello")
    await client.delete(f"/api/v1/cards/{card['id']}")

    found = await script.find_cards_missing_term_audio(db)
    assert found == []


async def test_count_matches_the_number_found(db, card_factory):
    for term in ["a", "b", "c"]:
        await card_factory(term)

    assert await script.count_cards_missing_term_audio(db) == 3
    assert len(await script.find_cards_missing_term_audio(db)) == 3


async def test_limit_caps_how_many_are_returned(db, card_factory):
    for term in ["a", "b", "c"]:
        await card_factory(term)

    found = await script.find_cards_missing_term_audio(db, limit=2)
    assert len(found) == 2


# --------------------------------------------------------------- backfill --
# `stub_piper` turns TTS on — pulled in via `request.getfixturevalue` *after*
# `card_factory` runs in each test below, not as a normal fixture parameter.
# Requesting it upfront would enable auto-generation for card_factory's own
# HTTP calls too, and every card would already have its clip before
# `backfill()` ever ran, defeating the "missing audio" setup entirely.


async def test_backfill_generates_a_clip_for_every_missing_card(db, client, card_factory, request):
    for term in ["hello", "window", "спасибо"]:
        await card_factory(term)
    request.getfixturevalue("stub_piper")

    result = await script.backfill(db, client.storage)

    assert result.total_missing == 3
    assert result.processed == 3
    assert result.generated == 3
    assert result.skipped == 0
    assert await script.count_cards_missing_term_audio(db) == 0


async def test_backfill_respects_limit_and_is_resumable(db, client, card_factory, request):
    for term in ["a", "b", "c", "d", "e"]:
        await card_factory(term)
    request.getfixturevalue("stub_piper")

    first = await script.backfill(db, client.storage, limit=2)
    assert first.total_missing == 5
    assert first.processed == 2
    assert first.generated == 2
    assert await script.count_cards_missing_term_audio(db) == 3

    second = await script.backfill(db, client.storage)
    assert second.total_missing == 3
    assert second.generated == 3
    assert await script.count_cards_missing_term_audio(db) == 0


async def test_backfill_counts_a_failed_card_as_skipped_not_generated(
    db, client, card_factory, request, monkeypatch
):
    from app.services import tts as tts_service

    await card_factory("first")
    await card_factory("second")
    request.getfixturevalue("stub_piper")

    calls = {"n": 0}
    real_load_voice = tts_service._load_voice

    def flaky_load_voice(lang: str):
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("synthesis blew up")
        return real_load_voice(lang)

    monkeypatch.setattr(tts_service, "_load_voice", flaky_load_voice)

    result = await script.backfill(db, client.storage)
    assert result.processed == 2
    assert result.generated == 1
    assert result.skipped == 1


async def test_backfill_progress_callback_wraps_the_card_list(db, client, card_factory, request):
    for term in ["a", "b"]:
        await card_factory(term)
    request.getfixturevalue("stub_piper")

    seen = []

    def spy(cards):
        seen.extend(cards)
        return cards

    await script.backfill(db, client.storage, progress=spy)
    assert len(seen) == 2


async def test_generated_clips_are_playable_through_the_normal_download_path(
    db, client, card_factory, request, wav_bytes
):
    card = await card_factory("hello")
    request.getfixturevalue("stub_piper")
    await script.backfill(db, client.storage)

    clips = (await client.get(f"/api/v1/cards/{card['id']}/audio")).json()
    assert len(clips) == 1
    assert clips[0]["side"] == AudioSide.TERM.value

    download = await client.get(f"/api/v1/audio/{clips[0]['id']}")
    assert download.status_code == 200
    assert download.content == wav_bytes

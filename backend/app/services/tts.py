"""Server-side term pronunciation.

Runs after a card is created: guesses the term's language, and if a Piper
voice is configured for it, synthesizes a WAV clip and stores it exactly like
a manually uploaded one (see ``app/api/v1/audio.py``). Every entry point here
is best-effort — a card whose term can't be pronounced is just a card with
no audio clip, same as one nobody got around to recording, and generation
must never turn a successful card creation into a failed request.

Language detection is deliberately restricted to the languages
``settings.tts_voice_map`` actually has a voice for, via ``langid.
set_languages()``. langid's accuracy across its full ~100-language set is
weak on a single word — verified empirically: ordinary five-letter English
words like "hello" score around 0.17 confidence against all languages, and
"run" is misclassified as German at 0.53. Restricted to just the collection's
configured languages, the same classifier is reliable, because script alone
(Latin vs Cyrillic, etc.) already separates most real cases.
"""

from __future__ import annotations

import asyncio
import functools
import io
import logging
import uuid
import wave
from collections.abc import AsyncIterator
from pathlib import Path

import numpy as np
import py3langid as langid
from piper import PiperVoice
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.models.audio_clip import AudioClip, AudioSide
from app.models.card import Card
from app.storage.base import Storage

logger = logging.getLogger("enka")


def detect_language(text: str) -> str | None:
    """Best-effort language code for `text`, restricted to configured voices.

    Returns None for blank text, no configured voices, or a guess below
    `settings.tts_min_confidence`.
    """
    stripped = text.strip()
    if not stripped or not settings.tts_voice_map:
        return None

    langid.set_languages(sorted(settings.tts_voice_map))
    ranked = langid.rank(stripped)
    scores = np.array([score for _, score in ranked], dtype=float)
    # Raw langid scores are unnormalized log-likelihoods, not probabilities.
    # Softmax over the (now small, voice-map-sized) candidate set turns them
    # into a genuine 0-1 confidence for the winner.
    scores -= scores.max()
    probs = np.exp(scores)
    top_lang, top_prob = ranked[0][0], float(probs[0] / probs.sum())
    return top_lang if top_prob >= settings.tts_min_confidence else None


@functools.lru_cache(maxsize=32)
def _load_voice(lang: str) -> PiperVoice | None:
    """Loads and caches a Piper voice by language code. Blocking — call via a thread."""
    voice_name = settings.tts_voice_map.get(lang)
    if voice_name is None:
        return None
    model_path = Path(settings.tts_model_dir) / f"{voice_name}.onnx"
    if not model_path.is_file():
        logger.warning("tts: voice model missing for lang=%r at %s", lang, model_path)
        return None
    return PiperVoice.load(str(model_path))


def _synthesize_wav_bytes(voice: PiperVoice, text: str) -> bytes:
    """Runs Piper inference and returns a whole WAV file. Blocking — call via a thread."""
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav_file:
        voice.synthesize_wav(text, wav_file)
    return buffer.getvalue()


async def generate_term_clip(session: AsyncSession, storage: Storage, card: Card) -> None:
    """Synthesizes and stores a term-side clip for `card`, best-effort.

    Meant to run as a ``BackgroundTasks`` entry scheduled from the card-create
    endpoints, reusing the same request session and storage — see the
    `Depends`-with-yield / background-task ordering note in
    ``app/api/v1/cards.py``. Never raises.
    """
    if not settings.tts_enabled:
        return
    lang = detect_language(card.term)
    if lang is None:
        return

    try:
        voice = await asyncio.to_thread(_load_voice, lang)
        if voice is None:
            return
        wav_bytes = await asyncio.to_thread(_synthesize_wav_bytes, voice, card.term)
    except Exception:
        logger.exception("tts: synthesis failed for card %s (lang=%s)", card.id, lang)
        return
    if not wav_bytes:
        return

    clip_id = uuid.uuid4()
    storage_key = f"{card.id}/{clip_id}.wav"

    async def chunks() -> AsyncIterator[bytes]:
        yield wav_bytes

    try:
        stored = await storage.save(storage_key, chunks(), max_bytes=settings.max_audio_bytes)
    except Exception:
        logger.exception("tts: failed to store generated clip for card %s", card.id)
        return

    clip = AudioClip(
        id=clip_id,
        owner_id=card.owner_id,
        card_id=card.id,
        side=AudioSide.TERM,
        storage_key=stored.key,
        original_filename=None,
        content_type="audio/wav",
        size_bytes=stored.size_bytes,
        sha256=stored.sha256,
    )
    session.add(clip)
    try:
        await session.commit()
    except Exception:
        logger.exception("tts: failed to save clip row for card %s", card.id)
        await session.rollback()
        await storage.delete(storage_key)

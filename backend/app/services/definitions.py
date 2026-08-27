"""AI-generated card definitions: a same-language gloss, or a translation.

Unlike app/services/tts.py, this runs synchronously inside the request — the
user clicked a button and is watching a spinner, not something that happens
unattended in the background. A failure here must become a real HTTP error;
swallowing it the way generate_term_clip does would leave the client waiting
on a response that never explains what went wrong.
"""

from __future__ import annotations

import logging
import time

from app.core.errors import ServiceUnavailableError, ValidationError
from app.schemas.definitions import DefinitionMode
from app.services.ai_cloud import AICloudClient, AICloudError

logger = logging.getLogger("enka")

#: Generous for "short but precise" — well under Card.definition's 10,000
#: char limit, but enough to cap a model that ignores the prompt's ask for
#: brevity and starts explaining itself.
_MAX_DEFINITION_LENGTH = 500

#: Above this many words a term reads as a sentence rather than a vocabulary
#: item. Asking for "the 2-3 most common equivalents" there makes the model
#: paraphrase one meaning three ways instead of listing distinct ones.
_MULTI_EQUIVALENT_MAX_WORDS = 3


def _is_short_term(term: str) -> bool:
    """True for a vocabulary item ("lock", "get up"), false for a sentence.

    A sentence has one faithful translation; only a word or short phrase has
    several distinct dictionary meanings worth listing.
    """
    stripped = term.strip()
    words = stripped.split()
    if not words or len(words) > _MULTI_EQUIVALENT_MAX_WORDS:
        return False
    # Terminal punctuation marks a sentence — but only alongside another
    # word, since a lone "lock." is someone typing a vocabulary item with a
    # full stop, not a sentence.
    if len(words) > 1 and stripped.rstrip("…").endswith((".", "!", "?")):
        return False
    # Punctuation left *inside* means more than one clause, however few
    # words each clause has.
    return not any(mark in stripped.rstrip(".!?…") for mark in ".!?")


def _build_prompt(term: str, mode: DefinitionMode, native_language: str | None) -> str:
    if mode is DefinitionMode.SAME_LANGUAGE:
        return (
            "You are a concise dictionary. Detect the language of the term "
            "below and write one short, precise definition of it, in that "
            "same language. Output only the definition — no preamble, no "
            "quotes, no markdown, no restating the term.\n\n"
            f"Term: {term}"
        )
    if not _is_short_term(term):
        return (
            f"Translate the text below into {native_language}. Give one "
            "faithful translation of the whole thing — not alternatives, not "
            "a word-by-word gloss, not an explanation. Output only the "
            "translation — no preamble, no quotes, no markdown.\n\n"
            f"Text: {term}"
        )
    return (
        f"Translate the term below into {native_language}. Give the 2-3 most "
        "common equivalents, separated by commas, ordered from most to least "
        "common — covering the term's distinct meanings if it has several "
        '(e.g. "lock" -> "замок, запирать"). Give a single equivalent only '
        "if the term really has just one common translation. Equivalents "
        "only, not explanations. Output only the translation — no preamble, "
        "no quotes, no markdown.\n\n"
        f"Term: {term}"
    )


def _prompt_variant(term: str, mode: DefinitionMode) -> str:
    """Names which of the three prompts was built, for the log line."""
    if mode is DefinitionMode.SAME_LANGUAGE:
        return "gloss"
    return "equivalents" if _is_short_term(term) else "sentence"


def _elapsed_ms(started: float) -> int:
    return int((time.monotonic() - started) * 1000)


def _sanitize(text: str) -> str:
    """Strips the formatting a small local model adds despite being told not to."""
    cleaned = text.strip()
    if len(cleaned) >= 2 and cleaned[0] in "\"'" and cleaned[-1] == cleaned[0]:
        cleaned = cleaned[1:-1].strip()
    # Some models answer, then add an explanation after a blank line — keep
    # only the first paragraph.
    cleaned = cleaned.split("\n\n")[0].strip()
    if len(cleaned) > _MAX_DEFINITION_LENGTH:
        cleaned = cleaned[:_MAX_DEFINITION_LENGTH].rstrip()
    return cleaned


async def generate_definition(
    client: AICloudClient,
    term: str,
    mode: DefinitionMode,
    native_language: str | None,
) -> str:
    """Returns a suggested definition/translation for `term`. Never writes to the DB.

    Raises `ValidationError` if translation was requested with no native
    language configured, or `ServiceUnavailableError` if the AI provider is
    unreachable or returns something unusable.
    """
    if mode is DefinitionMode.NATIVE_LANGUAGE and not native_language:
        raise ValidationError(
            "Set your native language first (PATCH /api/v1/auth/me) before "
            "requesting a translation."
        )

    prompt = _build_prompt(term, mode, native_language)
    logger.info(
        "ai: requesting %s definition for %r (lang=%s, prompt=%s, %d chars)",
        mode.value,
        term,
        native_language or "-",
        _prompt_variant(term, mode),
        len(prompt),
    )
    # The prompt is the thing you actually need when the output is wrong, but
    # it's ~400 chars of boilerplate on every card — DEBUG, not INFO.
    logger.debug("ai: prompt >>>\n%s", prompt)

    started = time.monotonic()
    try:
        raw = await client.generate(prompt)
    except AICloudError as exc:
        logger.warning(
            "ai: %s definition for %r failed after %d ms: %s",
            mode.value,
            term,
            _elapsed_ms(started),
            exc,
        )
        raise ServiceUnavailableError(
            "The definition service is unavailable right now. Try again shortly.",
            {"reason": str(exc)},
        ) from exc

    logger.debug("ai: raw response <<<\n%s", raw)
    definition = _sanitize(raw)
    if not definition:
        logger.warning(
            "ai: %s definition for %r came back empty after sanitizing (raw was %d chars)",
            mode.value,
            term,
            len(raw),
        )
        raise ServiceUnavailableError("The definition service returned an empty result.")

    logger.info(
        "ai: %s definition for %r ok in %d ms -> %r",
        mode.value,
        term,
        _elapsed_ms(started),
        definition,
    )
    return definition

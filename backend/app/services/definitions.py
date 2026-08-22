"""AI-generated card definitions: a same-language gloss, or a translation.

Unlike app/services/tts.py, this runs synchronously inside the request — the
user clicked a button and is watching a spinner, not something that happens
unattended in the background. A failure here must become a real HTTP error;
swallowing it the way generate_term_clip does would leave the client waiting
on a response that never explains what went wrong.
"""

from __future__ import annotations

from app.core.errors import ServiceUnavailableError, ValidationError
from app.schemas.definitions import DefinitionMode
from app.services.ollama import OllamaClient, OllamaError

#: Generous for "short but precise" — well under Card.definition's 10,000
#: char limit, but enough to cap a model that ignores the prompt's ask for
#: brevity and starts explaining itself.
_MAX_DEFINITION_LENGTH = 500


def _build_prompt(term: str, mode: DefinitionMode, native_language: str | None) -> str:
    if mode is DefinitionMode.SAME_LANGUAGE:
        return (
            "You are a concise dictionary. Detect the language of the term "
            "below and write one short, precise definition of it, in that "
            "same language. Output only the definition — no preamble, no "
            "quotes, no markdown, no restating the term.\n\n"
            f"Term: {term}"
        )
    return (
        f"Translate the term below into {native_language}. Give the 2-3 most "
        "common equivalents, separated by commas, ordered from most to least "
        "common — covering the term's distinct meanings if it has several "
        "(e.g. \"lock\" -> \"замок, запирать\"). Give a single equivalent only "
        "if the term really has just one common translation. Equivalents "
        "only, not explanations. Output only the translation — no preamble, "
        "no quotes, no markdown.\n\n"
        f"Term: {term}"
    )


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
    client: OllamaClient,
    term: str,
    mode: DefinitionMode,
    native_language: str | None,
) -> str:
    """Returns a suggested definition/translation for `term`. Never writes to the DB.

    Raises `ValidationError` if translation was requested with no native
    language configured, or `ServiceUnavailableError` if Ollama is
    unreachable or returns something unusable.
    """
    if mode is DefinitionMode.NATIVE_LANGUAGE and not native_language:
        raise ValidationError(
            "Set your native language first (PATCH /api/v1/auth/me) before "
            "requesting a translation."
        )

    prompt = _build_prompt(term, mode, native_language)
    try:
        raw = await client.generate(prompt)
    except OllamaError as exc:
        raise ServiceUnavailableError(
            "The definition service is unavailable right now. Try again shortly.",
            {"reason": str(exc)},
        ) from exc

    definition = _sanitize(raw)
    if not definition:
        raise ServiceUnavailableError("The definition service returned an empty result.")
    return definition

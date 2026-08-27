"""AI-generated definitions/translations.

A real cloud AI provider isn't available in CI, so every test replaces
`get_ai_client` with `_FakeAIClient` via `app.dependency_overrides` — the
same seam `get_storage` uses for `LocalStorage` in `app_client`.
"""

from __future__ import annotations

import logging

import pytest

from app.api.deps import get_ai_client
from app.core.errors import ServiceUnavailableError, ValidationError
from app.schemas.definitions import DefinitionMode
from app.services import definitions as definitions_service
from app.services.ai_cloud import AICloudError


class _FakeAIClient:
    def __init__(self, response: str | Exception):
        self._response = response

    async def generate(self, prompt: str) -> str:
        self.last_prompt = prompt
        if isinstance(self._response, Exception):
            raise self._response
        return self._response


@pytest.fixture
def stub_ai():
    """Returns a setter: `stub_ai("some text")` or `stub_ai(AICloudError(...))`."""
    from app.main import app

    fake = _FakeAIClient("")

    def _set(response: str | Exception) -> _FakeAIClient:
        fake._response = response
        return fake

    app.dependency_overrides[get_ai_client] = lambda: fake
    yield _set
    app.dependency_overrides.pop(get_ai_client, None)


# ---------------------------------------------------------------- prompts --
def test_same_language_prompt_does_not_need_a_native_language():
    prompt = definitions_service._build_prompt("hello", DefinitionMode.SAME_LANGUAGE, None)
    assert "hello" in prompt
    assert "same language" in prompt


def test_native_language_prompt_names_the_target():
    prompt = definitions_service._build_prompt("hello", DefinitionMode.NATIVE_LANGUAGE, "ru")
    assert "hello" in prompt
    assert "ru" in prompt


def test_native_language_prompt_asks_for_several_equivalents():
    prompt = definitions_service._build_prompt("lock", DefinitionMode.NATIVE_LANGUAGE, "ru")
    assert "2-3" in prompt


@pytest.mark.parametrize(
    "term",
    ["lock", "  lock  ", "get up", "take care of", "Wie geht's"],
)
def test_short_terms_get_the_multi_equivalent_prompt(term):
    assert definitions_service._is_short_term(term) is True
    prompt = definitions_service._build_prompt(term, DefinitionMode.NATIVE_LANGUAGE, "ru")
    assert "2-3" in prompt


@pytest.mark.parametrize(
    "term",
    [
        "I have been waiting for you",
        "It is raining.",
        "Stop! Look around.",
        "Wie geht es dir heute?",
        "",
        "   ",
    ],
)
def test_sentences_get_the_single_translation_prompt(term):
    assert definitions_service._is_short_term(term) is False
    prompt = definitions_service._build_prompt(term, DefinitionMode.NATIVE_LANGUAGE, "ru")
    assert "2-3" not in prompt
    assert "one faithful translation" in prompt


def test_trailing_period_does_not_make_a_word_a_sentence():
    assert definitions_service._is_short_term("lock.") is True


# ------------------------------------------------------------- sanitizing --
@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("a small window", "a small window"),
        ('"a small window"', "a small window"),
        ("'a small window'", "a small window"),
        ("  a small window  \n", "a small window"),
        ("a small window\n\nThis word is used for...", "a small window"),
    ],
)
def test_sanitize_strips_formatting_models_add_anyway(raw, expected):
    assert definitions_service._sanitize(raw) == expected


def test_sanitize_caps_length():
    huge = "x" * 10_000
    result = definitions_service._sanitize(huge)
    assert len(result) == definitions_service._MAX_DEFINITION_LENGTH


# --------------------------------------------------------- service (unit) --
class _StubClient:
    def __init__(self, response: str | Exception):
        self._response = response

    async def generate(self, prompt: str) -> str:
        if isinstance(self._response, Exception):
            raise self._response
        return self._response


async def test_generate_definition_same_language_needs_no_native_language():
    result = await definitions_service.generate_definition(
        _StubClient("a window"), "das Fenster", DefinitionMode.SAME_LANGUAGE, None
    )
    assert result == "a window"


async def test_generate_definition_translation_without_native_language_raises():
    with pytest.raises(ValidationError):
        await definitions_service.generate_definition(
            _StubClient("unused"), "das Fenster", DefinitionMode.NATIVE_LANGUAGE, None
        )


async def test_generate_definition_translation_with_native_language():
    result = await definitions_service.generate_definition(
        _StubClient("окно"), "das Fenster", DefinitionMode.NATIVE_LANGUAGE, "ru"
    )
    assert result == "окно"


async def test_generate_definition_wraps_ai_cloud_errors():
    with pytest.raises(ServiceUnavailableError):
        await definitions_service.generate_definition(
            _StubClient(AICloudError("connection refused")),
            "hello",
            DefinitionMode.SAME_LANGUAGE,
            None,
        )


async def test_generate_definition_empty_response_is_service_unavailable():
    with pytest.raises(ServiceUnavailableError):
        await definitions_service.generate_definition(
            _StubClient('""'), "hello", DefinitionMode.SAME_LANGUAGE, None
        )


# --------------------------------------------------------- endpoint (e2e) --
# /api/v1/definitions/generate is deliberately not card-scoped: the Add flow
# in both clients calls it on a term that hasn't been saved as a card yet,
# same endpoint the edit flow uses on an existing one's term.
async def test_generate_endpoint_same_language(client, stub_ai):
    stub_ai("a window, especially in a house")

    response = await client.post(
        "/api/v1/definitions/generate", json={"term": "das Fenster", "mode": "same_language"}
    )
    assert response.status_code == 200
    assert response.json()["definition"] == "a window, especially in a house"


async def test_generate_endpoint_never_writes_anything(client, stub_ai):
    """No card, no owner state — the response is the only effect."""
    stub_ai("a window")

    response = await client.post(
        "/api/v1/definitions/generate", json={"term": "das Fenster", "mode": "same_language"}
    )
    assert response.status_code == 200

    cards = (await client.get("/api/v1/cards?q=das Fenster")).json()
    assert cards["total"] == 0


async def test_generate_endpoint_blank_term_is_422(client, stub_ai):
    stub_ai("unused")
    response = await client.post(
        "/api/v1/definitions/generate", json={"term": "   ", "mode": "same_language"}
    )
    assert response.status_code == 422


async def test_generate_endpoint_translation_without_native_language_is_a_clear_error(
    client, stub_ai
):
    stub_ai("unused")

    response = await client.post(
        "/api/v1/definitions/generate", json={"term": "das Fenster", "mode": "native_language"}
    )
    assert response.status_code == 422
    assert "native language" in response.json()["error"]["message"].lower()


async def test_generate_endpoint_translation_with_native_language_set(client, stub_ai):
    await client.patch("/api/v1/auth/me", json={"native_language": "ru"})
    stub_ai("окно")

    response = await client.post(
        "/api/v1/definitions/generate", json={"term": "das Fenster", "mode": "native_language"}
    )
    assert response.status_code == 200
    assert response.json()["definition"] == "окно"


async def test_generate_endpoint_ai_cloud_unreachable_is_503(client, stub_ai):
    stub_ai(AICloudError("connection refused"))

    response = await client.post(
        "/api/v1/definitions/generate", json={"term": "das Fenster", "mode": "same_language"}
    )
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "service_unavailable"


async def test_generate_endpoint_requires_authentication(anon_client, force_owner, stub_ai):
    stub_ai("unused")

    from app.api.deps import get_current_owner
    from app.main import app

    app.dependency_overrides.pop(get_current_owner, None)
    response = await anon_client.post(
        "/api/v1/definitions/generate", json={"term": "das Fenster", "mode": "same_language"}
    )
    assert response.status_code == 401


# ---------------------------------------------------------------- logging --
@pytest.fixture
def enka_logs():
    """Collects everything the "enka" logger emits during the test.

    Deliberately not `caplog`: the app's `setup_logging()` rebuilds the root
    handlers, so whether records reach caplog's handler depends on which
    tests ran first. A handler on the "enka" logger itself sidesteps all of
    that and captures the same records either way.
    """
    records: list[logging.LogRecord] = []

    class _Collect(logging.Handler):
        def emit(self, record: logging.LogRecord) -> None:
            records.append(record)

    logger = logging.getLogger("enka")
    handler = _Collect()
    previous_level = logger.level
    logger.setLevel(logging.DEBUG)
    logger.addHandler(handler)
    try:
        yield records
    finally:
        logger.removeHandler(handler)
        logger.setLevel(previous_level)


def _text(records: list[logging.LogRecord]) -> str:
    return "\n".join(record.getMessage() for record in records)


async def test_success_is_logged_with_the_prompt_kind_and_result(enka_logs):
    client = _FakeAIClient("замок, запирать")
    await definitions_service.generate_definition(
        client, "lock", DefinitionMode.NATIVE_LANGUAGE, "ru"
    )

    logged = _text(enka_logs)
    assert "prompt=equivalents" in logged
    assert "ok in" in logged
    assert "замок, запирать" in logged
    # The prompt text itself is DEBUG-level, but must be there when DEBUG is on.
    assert "2-3" in logged


async def test_sentence_translation_logs_the_other_prompt_kind(enka_logs):
    client = _FakeAIClient("Я ждал тебя")
    await definitions_service.generate_definition(
        client, "I have been waiting for you", DefinitionMode.NATIVE_LANGUAGE, "ru"
    )
    assert "prompt=sentence" in _text(enka_logs)


async def test_failure_is_logged_with_the_reason(enka_logs):
    client = _FakeAIClient(AICloudError("connection refused"))
    with pytest.raises(ServiceUnavailableError):
        await definitions_service.generate_definition(
            client, "lock", DefinitionMode.NATIVE_LANGUAGE, "ru"
        )

    logged = _text(enka_logs)
    assert "failed after" in logged
    assert "connection refused" in logged
    assert any(record.levelno == logging.WARNING for record in enka_logs)


async def test_empty_result_is_logged_as_a_warning(enka_logs):
    client = _FakeAIClient("   ")
    with pytest.raises(ServiceUnavailableError):
        await definitions_service.generate_definition(
            client, "lock", DefinitionMode.NATIVE_LANGUAGE, "ru"
        )
    assert "empty" in _text(enka_logs)

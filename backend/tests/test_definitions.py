"""AI-generated definitions/translations.

A real Ollama server isn't available in CI, so every test replaces
`get_ollama_client` with `_FakeOllamaClient` via `app.dependency_overrides` —
the same seam `get_storage` uses for `LocalStorage` in `app_client`.
"""

from __future__ import annotations

import pytest

from app.api.deps import get_ollama_client
from app.core.errors import ServiceUnavailableError, ValidationError
from app.schemas.definitions import DefinitionMode
from app.services import definitions as definitions_service
from app.services.ollama import OllamaError


class _FakeOllamaClient:
    def __init__(self, response: str | Exception):
        self._response = response

    async def generate(self, prompt: str) -> str:
        self.last_prompt = prompt
        if isinstance(self._response, Exception):
            raise self._response
        return self._response


@pytest.fixture
def stub_ollama():
    """Returns a setter: `stub_ollama("some text")` or `stub_ollama(OllamaError(...))`."""
    from app.main import app

    fake = _FakeOllamaClient("")

    def _set(response: str | Exception) -> _FakeOllamaClient:
        fake._response = response
        return fake

    app.dependency_overrides[get_ollama_client] = lambda: fake
    yield _set
    app.dependency_overrides.pop(get_ollama_client, None)


# ---------------------------------------------------------------- prompts --
def test_same_language_prompt_does_not_need_a_native_language():
    prompt = definitions_service._build_prompt("hello", DefinitionMode.SAME_LANGUAGE, None)
    assert "hello" in prompt
    assert "same language" in prompt


def test_native_language_prompt_names_the_target():
    prompt = definitions_service._build_prompt("hello", DefinitionMode.NATIVE_LANGUAGE, "ru")
    assert "hello" in prompt
    assert "ru" in prompt


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


async def test_generate_definition_wraps_ollama_errors():
    with pytest.raises(ServiceUnavailableError):
        await definitions_service.generate_definition(
            _StubClient(OllamaError("connection refused")),
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
async def test_generate_endpoint_same_language(client, card_factory, stub_ollama):
    stub_ollama("a window, especially in a house")
    card = await card_factory("das Fenster")

    response = await client.post(
        f"/api/v1/cards/{card['id']}/definition/generate", json={"mode": "same_language"}
    )
    assert response.status_code == 200
    assert response.json()["definition"] == "a window, especially in a house"


async def test_generate_endpoint_never_writes_to_the_card(client, card_factory, stub_ollama):
    stub_ollama("a window")
    card = await card_factory("das Fenster")

    await client.post(
        f"/api/v1/cards/{card['id']}/definition/generate", json={"mode": "same_language"}
    )

    fetched = (await client.get(f"/api/v1/cards/{card['id']}")).json()
    assert fetched["definition"] is None


async def test_generate_endpoint_translation_without_native_language_is_a_clear_error(
    client, card_factory, stub_ollama
):
    stub_ollama("unused")
    card = await card_factory("das Fenster")

    response = await client.post(
        f"/api/v1/cards/{card['id']}/definition/generate", json={"mode": "native_language"}
    )
    assert response.status_code == 422
    assert "native language" in response.json()["error"]["message"].lower()


async def test_generate_endpoint_translation_with_native_language_set(
    client, card_factory, stub_ollama
):
    await client.patch("/api/v1/auth/me", json={"native_language": "ru"})
    stub_ollama("окно")
    card = await card_factory("das Fenster")

    response = await client.post(
        f"/api/v1/cards/{card['id']}/definition/generate", json={"mode": "native_language"}
    )
    assert response.status_code == 200
    assert response.json()["definition"] == "окно"


async def test_generate_endpoint_unknown_card_is_404(client, stub_ollama, new_uuid):
    stub_ollama("unused")
    response = await client.post(
        f"/api/v1/cards/{new_uuid()}/definition/generate", json={"mode": "same_language"}
    )
    assert response.status_code == 404


async def test_generate_endpoint_ollama_unreachable_is_503(client, card_factory, stub_ollama):
    stub_ollama(OllamaError("connection refused"))
    card = await card_factory("das Fenster")

    response = await client.post(
        f"/api/v1/cards/{card['id']}/definition/generate", json={"mode": "same_language"}
    )
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "service_unavailable"


async def test_generate_endpoint_requires_authentication(anon_client, force_owner, stub_ollama):
    stub_ollama("unused")
    card = (await anon_client.post("/api/v1/cards", json={"term": "word"})).json()

    from app.api.deps import get_current_owner
    from app.main import app

    app.dependency_overrides.pop(get_current_owner, None)
    response = await anon_client.post(
        f"/api/v1/cards/{card['id']}/definition/generate", json={"mode": "same_language"}
    )
    assert response.status_code == 401

"""Direct unit tests for AICloudClient.

Nothing else in the suite exercises its real HTTP/parsing logic — every test
in test_definitions.py replaces it entirely with a fake at the get_ai_client
dependency seam. These tests cover AICloudClient.generate() itself: the
success path and every AICloudError branch (non-2xx status, non-JSON body,
missing/malformed choices, empty content).
"""

from __future__ import annotations

import httpx
import pytest

from app.services.ai_cloud import AICloudClient, AICloudError


class _FakeResponse:
    def __init__(self, status_code=200, payload=None, is_json=True):
        self.status_code = status_code
        self._payload = payload
        self._is_json = is_json

    def raise_for_status(self):
        if self.status_code >= 400:
            request = httpx.Request("POST", "https://api.deepseek.com/chat/completions")
            response = httpx.Response(self.status_code, request=request)
            raise httpx.HTTPStatusError("bad status", request=request, response=response)

    def json(self):
        if not self._is_json:
            raise ValueError("not json")
        return self._payload


def _patch_post(monkeypatch, response):
    async def fake_post(self, url, headers=None, json=None):
        return response

    monkeypatch.setattr(httpx.AsyncClient, "post", fake_post)


def _client() -> AICloudClient:
    return AICloudClient("https://api.deepseek.com", "deepseek-v4-flash", "key", 5.0)


async def test_generate_returns_content_on_success(monkeypatch):
    _patch_post(
        monkeypatch,
        _FakeResponse(200, {"choices": [{"message": {"content": "a window"}}]}),
    )
    result = await _client().generate("define das Fenster")
    assert result == "a window"


@pytest.mark.parametrize(
    ("base_url", "disable_thinking", "expected"),
    [
        ("https://api.deepseek.com", True, {"thinking": {"type": "disabled"}}),
        ("https://openrouter.ai/api/v1", True, {"reasoning": {"effort": "none"}}),
        ("https://api.deepseek.com", False, {}),
        ("https://openrouter.ai/api/v1", False, {}),
    ],
)
async def test_generate_turns_thinking_off_in_the_providers_dialect(
    monkeypatch, base_url, disable_thinking, expected
):
    """Both fields are off-spec — each provider gets only its own, and a
    provider that rejects unknown fields must be able to get neither."""
    sent: dict = {}

    async def fake_post(self, url, headers=None, json=None):
        sent.update(json)
        return _FakeResponse(200, {"choices": [{"message": {"content": "a window"}}]})

    monkeypatch.setattr(httpx.AsyncClient, "post", fake_post)
    client = AICloudClient(
        base_url, "deepseek-v4-flash", "key", 5.0, disable_thinking=disable_thinking
    )
    await client.generate("define das Fenster")

    assert {k: sent[k] for k in ("thinking", "reasoning") if k in sent} == expected


async def test_generate_raises_on_non_2xx_status(monkeypatch):
    _patch_post(monkeypatch, _FakeResponse(401, {}))
    with pytest.raises(AICloudError):
        await _client().generate("define das Fenster")


async def test_generate_raises_on_non_json_body(monkeypatch):
    _patch_post(monkeypatch, _FakeResponse(200, None, is_json=False))
    with pytest.raises(AICloudError):
        await _client().generate("define das Fenster")


async def test_generate_raises_on_missing_choices(monkeypatch):
    _patch_post(monkeypatch, _FakeResponse(200, {"choices": []}))
    with pytest.raises(AICloudError):
        await _client().generate("define das Fenster")


@pytest.mark.parametrize(
    "payload",
    [
        {"choices": [None]},
        {"choices": [{"message": None}]},
        {"choices": {"message": {"content": "x"}}},
    ],
)
async def test_generate_raises_on_null_or_wrong_typed_shape(monkeypatch, payload):
    """Structurally-present but null/wrong-typed shapes raise TypeError, not
    KeyError/IndexError — they must still surface as AICloudError, not a 500."""
    _patch_post(monkeypatch, _FakeResponse(200, payload))
    with pytest.raises(AICloudError):
        await _client().generate("define das Fenster")


async def test_generate_raises_on_empty_content(monkeypatch):
    _patch_post(
        monkeypatch,
        _FakeResponse(200, {"choices": [{"message": {"content": "   "}}]}),
    )
    with pytest.raises(AICloudError):
        await _client().generate("define das Fenster")

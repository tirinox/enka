"""Thin async client for an OpenAI-compatible chat-completions API.

Kept separate from app/services/definitions.py (which owns prompting and
response handling) so it can be swapped for a fake in tests via
app.dependency_overrides — the same seam StorageDep uses for LocalStorage.

Targets the `/chat/completions` shape shared by DeepSeek, OpenAI, and most
other hosted providers, so switching provider is a `.env` edit (AI_URL,
AI_MODEL, AI_API_KEY), not a code change.
"""

from __future__ import annotations

import httpx


class AICloudError(Exception):
    """The cloud provider was unreachable, timed out, or returned something unusable."""


class AICloudClient:
    def __init__(self, base_url: str, model: str, api_key: str, timeout: float) -> None:
        self._base_url = base_url.rstrip("/")
        self._model = model
        self._api_key = api_key
        self._timeout = timeout

    async def generate(self, prompt: str) -> str:
        """Returns the model's raw text response.

        Raises AICloudError on any failure — connection refused, timeout,
        non-2xx status, or a response body that doesn't have the shape the
        chat-completions API documents.
        """
        try:
            async with httpx.AsyncClient(timeout=self._timeout) as client:
                response = await client.post(
                    f"{self._base_url}/chat/completions",
                    headers={"Authorization": f"Bearer {self._api_key}"},
                    json={
                        "model": self._model,
                        "messages": [{"role": "user", "content": prompt}],
                        "stream": False,
                        # Greedy decoding: a translation/definition has one best
                        # answer, not a range of creative ones.
                        "temperature": 0.0,
                    },
                )
                response.raise_for_status()
        except httpx.HTTPError as exc:
            raise AICloudError(f"AI cloud request failed: {exc}") from exc

        try:
            text = response.json()["choices"][0]["message"]["content"]
        except ValueError as exc:
            raise AICloudError("AI cloud provider returned a non-JSON response.") from exc
        # TypeError too: a provider that answers a refused/filtered prompt with
        # {"choices": [{"message": null}]} indexes into None, which is neither
        # a KeyError nor an IndexError.
        except (KeyError, IndexError, TypeError) as exc:
            raise AICloudError("AI cloud response had no choices[0].message.content.") from exc

        if not isinstance(text, str) or not text.strip():
            raise AICloudError("AI cloud provider returned an empty response.")
        return text

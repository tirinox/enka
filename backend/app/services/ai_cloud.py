"""Thin async client for an OpenAI-compatible chat-completions API.

Kept separate from app/services/definitions.py (which owns prompting and
response handling) so it can be swapped for a fake in tests via
app.dependency_overrides — the same seam StorageDep uses for LocalStorage.

Targets the `/chat/completions` shape shared by DeepSeek, OpenRouter, OpenAI,
and most other hosted providers, so switching provider is a `.env` edit
(AI_URL, AI_MODEL, AI_API_KEY), not a code change.
"""

from __future__ import annotations

import logging
from urllib.parse import urlsplit

import httpx

logger = logging.getLogger("enka")

#: Provider error bodies are short ("Insufficient Balance", "invalid api
#: key"); cap anyway so a provider returning an HTML error page can't dump
#: kilobytes into the log.
_MAX_LOGGED_BODY = 500


def _thinking_off_fields(base_url: str) -> dict:
    """The request fields that turn reasoning off, in the dialect of the
    provider at `base_url`. Neither is part of the OpenAI shape."""
    host = urlsplit(base_url).hostname or ""
    if host == "openrouter.ai" or host.endswith(".openrouter.ai"):
        # OpenRouter's own field, which it translates for whichever upstream
        # serves the model. DeepSeek's `thinking` is not guaranteed to be
        # forwarded, and means nothing to a non-DeepSeek host of the model.
        return {"reasoning": {"effort": "none"}}
    return {"thinking": {"type": "disabled"}}


class AICloudError(Exception):
    """The cloud provider was unreachable, timed out, or returned something unusable."""


class AICloudClient:
    def __init__(
        self,
        base_url: str,
        model: str,
        api_key: str,
        timeout: float,
        *,
        disable_thinking: bool = False,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._model = model
        self._api_key = api_key
        self._timeout = timeout
        self._thinking_fields = _thinking_off_fields(base_url) if disable_thinking else {}

    async def generate(self, prompt: str) -> str:
        """Returns the model's raw text response.

        Raises AICloudError on any failure — connection refused, timeout,
        non-2xx status, or a response body that doesn't have the shape the
        chat-completions API documents.
        """
        logger.debug(
            "ai_cloud: POST %s/chat/completions model=%s prompt=%d chars",
            self._base_url,
            self._model,
            len(prompt),
        )
        body: dict = {
            "model": self._model,
            "messages": [{"role": "user", "content": prompt}],
            "stream": False,
            # Greedy decoding: a translation/definition has one best answer,
            # not a range of creative ones. Only honoured with thinking off —
            # DeepSeek ignores temperature in thinking mode.
            "temperature": 0.0,
            # See ai_disable_thinking in app/core/config.py.
            **self._thinking_fields,
        }
        try:
            async with httpx.AsyncClient(timeout=self._timeout) as client:
                response = await client.post(
                    f"{self._base_url}/chat/completions",
                    headers={"Authorization": f"Bearer {self._api_key}"},
                    json=body,
                )
                response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            # The status alone rarely explains a 4xx — the body is where the
            # provider says "insufficient balance" or "invalid api key". It
            # never echoes the Authorization header, so it is safe to log.
            body = exc.response.text[:_MAX_LOGGED_BODY]
            logger.warning(
                "ai_cloud: %s returned HTTP %d: %s",
                self._model,
                exc.response.status_code,
                body,
            )
            raise AICloudError(f"AI cloud request failed: {exc}") from exc
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

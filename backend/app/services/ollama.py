"""Thin async client for a local Ollama server.

Kept separate from app/services/definitions.py (which owns prompting and
response handling) so it can be swapped for a fake in tests via
app.dependency_overrides — the same seam StorageDep uses for LocalStorage.
"""

from __future__ import annotations

import httpx


class OllamaError(Exception):
    """Ollama was unreachable, timed out, or returned something unusable."""


class OllamaClient:
    def __init__(self, base_url: str, model: str, timeout: float) -> None:
        self._base_url = base_url.rstrip("/")
        self._model = model
        self._timeout = timeout

    async def generate(self, prompt: str) -> str:
        """Returns the model's raw text response.

        Raises OllamaError on any failure — connection refused, timeout,
        non-2xx status, or a response body that doesn't have the shape
        Ollama's own API documents.
        """
        try:
            async with httpx.AsyncClient(timeout=self._timeout) as client:
                response = await client.post(
                    f"{self._base_url}/api/generate",
                    json={
                        "model": self._model,
                        "prompt": prompt,
                        "stream": False,
                        # Greedy decoding: a translation/definition has one best
                        # answer, not a range of creative ones. Verified this
                        # matters — default sampling produced wrong-language
                        # and outright mistranslated output on the same prompts
                        # that came back correct and consistent at temperature 0.
                        "options": {"temperature": 0.0},
                    },
                )
                response.raise_for_status()
        except httpx.HTTPError as exc:
            raise OllamaError(f"Ollama request failed: {exc}") from exc

        try:
            text = response.json()["response"]
        except ValueError as exc:
            raise OllamaError("Ollama returned a non-JSON response.") from exc
        except KeyError as exc:
            raise OllamaError("Ollama's response had no 'response' field.") from exc

        if not isinstance(text, str) or not text.strip():
            raise OllamaError("Ollama returned an empty response.")
        return text

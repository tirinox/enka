"""Shared-secret login, JWT issuing/verification, and a small login throttle."""

from __future__ import annotations

import hmac
import time
import uuid
from collections import defaultdict, deque
from datetime import UTC, datetime, timedelta
from typing import Any, Literal

import jwt

from app.core.config import settings
from app.core.errors import RateLimitedError, UnauthorizedError

TokenScope = Literal["api", "media"]


def verify_access_secret(candidate: str) -> bool:
    """Constant-time comparison — a timing side channel would shrink the
    search space on an already-short human-typed secret."""
    return hmac.compare_digest(candidate.strip(), settings.access_secret.strip())


def create_token(owner_id: uuid.UUID, scope: TokenScope = "api") -> tuple[str, datetime]:
    now = datetime.now(UTC)
    ttl = (
        timedelta(minutes=settings.media_token_ttl_minutes)
        if scope == "media"
        else timedelta(hours=settings.jwt_ttl_hours)
    )
    expires_at = now + ttl
    payload: dict[str, Any] = {
        "sub": str(owner_id),
        "scope": scope,
        "iat": int(now.timestamp()),
        "exp": int(expires_at.timestamp()),
        "iss": "enka",
    }
    token = jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)
    return token, expires_at


def decode_token(
    token: str, *, allowed_scopes: tuple[TokenScope, ...] = ("api",)
) -> dict[str, Any]:
    try:
        payload = jwt.decode(
            token,
            settings.jwt_secret,
            algorithms=[settings.jwt_algorithm],
            issuer="enka",
            options={"require": ["exp", "sub", "iss"]},
        )
    except jwt.ExpiredSignatureError as exc:
        raise UnauthorizedError("Token has expired. Sign in again.") from exc
    except jwt.InvalidTokenError as exc:
        raise UnauthorizedError("Invalid token.") from exc

    if payload.get("scope") not in allowed_scopes:
        raise UnauthorizedError("Token is not valid for this endpoint.")
    return payload


class LoginThrottle:
    """In-memory sliding window, keyed by client IP.

    Deliberately not Redis: this is a single-process personal deployment, and
    the goal is only to make guessing a short secret impractical. State resets
    on restart, which is fine.
    """

    def __init__(self, attempts: int, window_seconds: int) -> None:
        self.attempts = attempts
        self.window = window_seconds
        self._hits: dict[str, deque[float]] = defaultdict(deque)

    def check(self, key: str) -> None:
        now = time.monotonic()
        hits = self._hits[key]
        while hits and now - hits[0] > self.window:
            hits.popleft()
        if len(hits) >= self.attempts:
            retry_in = int(self.window - (now - hits[0])) + 1
            raise RateLimitedError(
                f"Too many failed attempts. Try again in {retry_in}s.",
                {"retry_after_seconds": retry_in},
            )

    def record_failure(self, key: str) -> None:
        self._hits[key].append(time.monotonic())

    def reset(self, key: str) -> None:
        self._hits.pop(key, None)


login_throttle = LoginThrottle(
    settings.auth_rate_limit_attempts,
    settings.auth_rate_limit_window_seconds,
)

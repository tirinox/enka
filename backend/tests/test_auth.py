from __future__ import annotations

from datetime import UTC, datetime, timedelta

import jwt
import pytest

from app.core.config import settings
from app.core.errors import UnauthorizedError
from app.core.security import create_token, decode_token
from tests.conftest import TEST_SECRET


async def test_token_exchange_returns_usable_jwt(anon_client, owner):
    response = await anon_client.post("/api/v1/auth/token", json={"secret": TEST_SECRET})
    assert response.status_code == 200
    body = response.json()
    assert body["token_type"] == "bearer"
    assert body["scope"] == "api"

    me = await anon_client.get(
        "/api/v1/auth/me", headers={"Authorization": f"Bearer {body['access_token']}"}
    )
    assert me.status_code == 200
    assert me.json()["owner_id"] == str(owner.id)


async def test_wrong_secret_is_rejected(anon_client, owner):
    response = await anon_client.post("/api/v1/auth/token", json={"secret": "nope"})
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthorized"


async def test_secret_comparison_is_not_prefix_based(anon_client, owner):
    """A prefix of the real secret must not authenticate."""
    response = await anon_client.post("/api/v1/auth/token", json={"secret": TEST_SECRET[:-1]})
    assert response.status_code == 401


async def test_missing_token_is_401(anon_client):
    response = await anon_client.get("/api/v1/cards")
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthorized"


async def test_garbage_token_is_401(anon_client):
    response = await anon_client.get("/api/v1/cards", headers={"Authorization": "Bearer not.a.jwt"})
    assert response.status_code == 401


async def test_expired_token_is_rejected(anon_client, owner):
    stale = jwt.encode(
        {
            "sub": str(owner.id),
            "scope": "api",
            "iss": "enka",
            "iat": int((datetime.now(UTC) - timedelta(hours=2)).timestamp()),
            "exp": int((datetime.now(UTC) - timedelta(hours=1)).timestamp()),
        },
        settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
    )
    response = await anon_client.get("/api/v1/cards", headers={"Authorization": f"Bearer {stale}"})
    assert response.status_code == 401
    assert "expired" in response.json()["error"]["message"].lower()


async def test_token_signed_with_another_key_is_rejected(anon_client, owner):
    forged = jwt.encode(
        {
            "sub": str(owner.id),
            "scope": "api",
            "iss": "enka",
            "exp": int((datetime.now(UTC) + timedelta(hours=1)).timestamp()),
        },
        "a-different-signing-key-also-padded-past-thirty-two",
        algorithm="HS256",
    )
    response = await anon_client.get("/api/v1/cards", headers={"Authorization": f"Bearer {forged}"})
    assert response.status_code == 401


async def test_login_throttle_kicks_in(anon_client, owner):
    for _ in range(settings.auth_rate_limit_attempts):
        assert (
            await anon_client.post("/api/v1/auth/token", json={"secret": "wrong"})
        ).status_code == 401

    blocked = await anon_client.post("/api/v1/auth/token", json={"secret": "wrong"})
    assert blocked.status_code == 429
    assert blocked.json()["error"]["code"] == "rate_limited"

    # Even the correct secret is refused while the window is open — that is the
    # point of the throttle.
    assert (
        await anon_client.post("/api/v1/auth/token", json={"secret": TEST_SECRET})
    ).status_code == 429


async def test_successful_login_clears_the_throttle(anon_client, owner):
    for _ in range(settings.auth_rate_limit_attempts - 1):
        await anon_client.post("/api/v1/auth/token", json={"secret": "wrong"})

    assert (
        await anon_client.post("/api/v1/auth/token", json={"secret": TEST_SECRET})
    ).status_code == 200
    # Counter reset, so a fresh run of failures is needed to trip it again.
    assert (
        await anon_client.post("/api/v1/auth/token", json={"secret": "wrong"})
    ).status_code == 401


async def test_media_token_has_its_own_scope(client, owner):
    response = await client.post("/api/v1/auth/media-token")
    assert response.status_code == 201
    assert response.json()["scope"] == "media"


async def test_media_token_cannot_call_the_regular_api(anon_client, owner):
    token, _ = create_token(owner.id, scope="media")
    response = await anon_client.get("/api/v1/cards", headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 401


def test_api_scope_rejected_where_only_media_allowed(owner):
    token, _ = create_token(owner.id, scope="api")
    with pytest.raises(UnauthorizedError):
        decode_token(token, allowed_scopes=("media",))


def test_media_token_expires_much_sooner_than_api_token(owner):
    _, api_expiry = create_token(owner.id, scope="api")
    _, media_expiry = create_token(owner.id, scope="media")
    assert media_expiry < api_expiry
    assert media_expiry - datetime.now(UTC) < timedelta(hours=1)

from __future__ import annotations

from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, Request, status
from sqlalchemy import select

from app.api.deps import OwnerDep, SessionDep, get_token_payload
from app.core.errors import UnauthorizedError
from app.core.security import create_token, login_throttle, verify_access_secret
from app.models.owner import Owner
from app.schemas.auth import MeResponse, MeUpdate, TokenRequest, TokenResponse

router = APIRouter(prefix="/auth", tags=["auth"])


def _client_key(request: Request) -> str:
    return request.client.host if request.client else "unknown"


@router.post(
    "/token",
    response_model=TokenResponse,
    summary="Exchange the shared secret for a JWT",
    description=(
        "Send the value of ENKA_ACCESS_SECRET from the server's .env. "
        "Returns a long-lived token to put in the Authorization header."
    ),
)
async def issue_token(
    payload: TokenRequest, request: Request, session: SessionDep
) -> TokenResponse:
    key = _client_key(request)
    login_throttle.check(key)

    if not verify_access_secret(payload.secret):
        login_throttle.record_failure(key)
        raise UnauthorizedError("Incorrect secret.")

    login_throttle.reset(key)
    owner = (await session.execute(select(Owner).limit(1))).scalar_one_or_none()
    if owner is None:
        # Should be impossible — the lifespan seeds it — but a clear error beats
        # a 500 if someone truncates the table.
        raise UnauthorizedError("Server has no owner configured. Restart the API to seed one.")

    token, expires_at = create_token(owner.id, scope="api")
    return TokenResponse(access_token=token, expires_at=expires_at, scope="api")


@router.post(
    "/media-token",
    response_model=TokenResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Mint a short-lived token for audio URLs",
    description=(
        "Browsers can't set headers on `<audio src>`. Use this token as "
        "`/api/v1/audio/{id}?token=...`; it expires within minutes."
    ),
)
async def issue_media_token(owner: OwnerDep) -> TokenResponse:
    token, expires_at = create_token(owner.id, scope="media")
    return TokenResponse(access_token=token, expires_at=expires_at, scope="media")


@router.get("/me", response_model=MeResponse, summary="Who am I, and until when")
async def me(
    owner: OwnerDep,
    payload: Annotated[dict, Depends(get_token_payload)],
) -> MeResponse:
    return MeResponse(
        owner_id=owner.id,
        name=owner.name,
        native_language=owner.native_language,
        token_expires_at=datetime.fromtimestamp(payload["exp"], tz=UTC),
    )


@router.patch(
    "/me",
    response_model=MeResponse,
    summary="Set your native language",
    description=(
        "Currently the only editable field. Used by the AI translation "
        "feature (POST /cards/{id}/definition/generate) to pick a target "
        "language — the client prompts for this the first time a "
        "translation is requested."
    ),
)
async def update_me(
    payload: MeUpdate,
    owner: OwnerDep,
    session: SessionDep,
    token_payload: Annotated[dict, Depends(get_token_payload)],
) -> MeResponse:
    owner.native_language = payload.native_language
    await session.commit()
    await session.refresh(owner)
    return MeResponse(
        owner_id=owner.id,
        name=owner.name,
        native_language=owner.native_language,
        token_expires_at=datetime.fromtimestamp(token_payload["exp"], tz=UTC),
    )

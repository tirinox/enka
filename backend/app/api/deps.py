from __future__ import annotations

import functools
import uuid
from typing import Annotated

from fastapi import Depends, Query, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.errors import UnauthorizedError
from app.core.security import TokenScope, decode_token
from app.db.session import get_session
from app.models.owner import Owner
from app.storage.local import LocalStorage

bearer_scheme = HTTPBearer(auto_error=False, description="JWT from POST /api/v1/auth/token")

SessionDep = Annotated[AsyncSession, Depends(get_session)]


@functools.lru_cache
def get_storage() -> LocalStorage:
    return LocalStorage(settings.audio_dir)


StorageDep = Annotated[LocalStorage, Depends(get_storage)]


async def _owner_from_token(session: AsyncSession, token: str, scopes: tuple[TokenScope, ...]):
    payload = decode_token(token, allowed_scopes=scopes)
    try:
        owner_id = uuid.UUID(payload["sub"])
    except (KeyError, ValueError) as exc:
        raise UnauthorizedError("Malformed token subject.") from exc

    owner = (await session.execute(select(Owner).where(Owner.id == owner_id))).scalar_one_or_none()
    if owner is None:
        raise UnauthorizedError("Token refers to an owner that no longer exists.")
    return owner, payload


async def get_current_owner(
    session: SessionDep,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)] = None,
) -> Owner:
    if credentials is None or not credentials.credentials:
        raise UnauthorizedError("Missing bearer token. POST /api/v1/auth/token first.")
    owner, _ = await _owner_from_token(session, credentials.credentials, ("api",))
    return owner


async def get_token_payload(
    session: SessionDep,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)] = None,
) -> dict:
    if credentials is None or not credentials.credentials:
        raise UnauthorizedError("Missing bearer token.")
    _, payload = await _owner_from_token(session, credentials.credentials, ("api",))
    return payload


async def get_media_owner(
    request: Request,
    session: SessionDep,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)] = None,
    token: Annotated[
        str | None,
        Query(description="Short-lived media token, for `<audio src>` which can't send headers."),
    ] = None,
) -> Owner:
    """Auth for audio streaming.

    A browser `<audio>` element cannot attach an Authorization header, so this
    endpoint alone also accepts the token as a query parameter. That token is
    minted separately by POST /auth/media-token and expires in minutes, so a
    URL leaking into a log or history is a much smaller problem than leaking
    the 30-day API token would be.
    """
    if credentials is not None and credentials.credentials:
        owner, _ = await _owner_from_token(session, credentials.credentials, ("api", "media"))
        return owner
    if token:
        owner, _ = await _owner_from_token(session, token, ("api", "media"))
        return owner
    raise UnauthorizedError("Missing bearer token or ?token= media token.")


OwnerDep = Annotated[Owner, Depends(get_current_owner)]
MediaOwnerDep = Annotated[Owner, Depends(get_media_owner)]

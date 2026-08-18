from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, File, Header, Query, Response, UploadFile, status
from fastapi.responses import StreamingResponse
from sqlalchemy import func, select

from app.api.deps import MediaOwnerDep, OwnerDep, SessionDep, StorageDep
from app.core.errors import EnkaError, NotFoundError
from app.models.audio_clip import AudioClip, AudioSide
from app.schemas.audio import AudioClipOut, AudioClipUpdate
from app.services import audio as audio_service
from app.services import cards as card_service

router = APIRouter(tags=["audio"])


class RangeNotSatisfiableError(EnkaError):
    status_code = status.HTTP_416_RANGE_NOT_SATISFIABLE
    code = "range_not_satisfiable"


async def _get_clip(session: SessionDep, owner_id: uuid.UUID, clip_id: uuid.UUID) -> AudioClip:
    clip = (
        await session.execute(
            select(AudioClip).where(AudioClip.id == clip_id, AudioClip.owner_id == owner_id)
        )
    ).scalar_one_or_none()
    if clip is None:
        raise NotFoundError(f"No audio clip with id {clip_id}.")
    return clip


@router.post(
    "/cards/{card_id}/audio",
    response_model=AudioClipOut,
    status_code=status.HTTP_201_CREATED,
    tags=["cards"],
    summary="Attach an audio clip to a card",
    description=(
        "Multipart upload of a native-speaker recording for one side of the card. "
        "Accepts mp3, m4a, ogg/opus, wav, flac and webm — the format is detected "
        "from the file's own bytes, not the declared content type."
    ),
)
async def upload_audio(
    card_id: uuid.UUID,
    owner: OwnerDep,
    session: SessionDep,
    storage: StorageDep,
    file: Annotated[UploadFile, File(description="The audio file.")],
    side: Annotated[AudioSide, Query(description="Which side of the card this reads aloud.")],
    duration_ms: Annotated[int | None, Query(ge=0)] = None,
) -> AudioClipOut:
    card = await card_service.get_card(session, owner.id, card_id)

    clip_id = uuid.uuid4()
    stored, content_type, storage_key = await audio_service.ingest_upload(
        storage, file, card_id=card.id, clip_id=clip_id, side=side
    )

    next_order = (
        await session.execute(
            select(func.coalesce(func.max(AudioClip.sort_order), -1) + 1).where(
                AudioClip.card_id == card.id, AudioClip.side == side
            )
        )
    ).scalar_one()

    clip = AudioClip(
        id=clip_id,
        owner_id=owner.id,
        card_id=card.id,
        side=side,
        storage_key=storage_key,
        original_filename=file.filename,
        content_type=content_type,
        size_bytes=stored.size_bytes,
        sha256=stored.sha256,
        duration_ms=duration_ms,
        sort_order=next_order,
    )
    session.add(clip)
    try:
        await session.commit()
    except Exception:
        # Don't leave the file orphaned if the row can't be written.
        await storage.delete(storage_key)
        raise
    await session.refresh(clip)
    return AudioClipOut.model_validate(clip)


@router.get(
    "/cards/{card_id}/audio",
    response_model=list[AudioClipOut],
    tags=["cards"],
    summary="List a card's clips",
)
async def list_audio(
    card_id: uuid.UUID,
    owner: OwnerDep,
    session: SessionDep,
    side: AudioSide | None = None,
) -> list[AudioClipOut]:
    card = await card_service.get_card(session, owner.id, card_id)
    clips = [c for c in card.audio_clips if side is None or c.side == side]
    return [AudioClipOut.model_validate(c) for c in clips]


@router.get(
    "/audio/{clip_id}",
    summary="Download or stream a clip",
    description=(
        "Supports HTTP Range so players can seek. Authenticate with a bearer "
        "token, or append `?token=` from POST /auth/media-token when using this "
        "URL directly in an `<audio>` element."
    ),
    responses={
        200: {"content": {"audio/*": {}}, "description": "Whole file"},
        206: {"content": {"audio/*": {}}, "description": "Partial content"},
    },
)
async def download_audio(
    clip_id: uuid.UUID,
    owner: MediaOwnerDep,
    session: SessionDep,
    storage: StorageDep,
    range_header: Annotated[str | None, Header(alias="Range")] = None,
) -> StreamingResponse:
    clip = await _get_clip(session, owner.id, clip_id)
    size = await storage.size(clip.storage_key)

    headers = {
        "Accept-Ranges": "bytes",
        "ETag": f'"{clip.sha256}"',
        "Cache-Control": "private, max-age=31536000, immutable",
        "Content-Disposition": f'inline; filename="{clip.original_filename or clip.storage_key}"',
    }

    try:
        parsed = audio_service.parse_range_header(range_header, size)
    except ValueError as exc:
        raise RangeNotSatisfiableError(
            "Requested range is not satisfiable.", {"size_bytes": size}
        ) from exc

    if parsed is None:
        headers["Content-Length"] = str(size)
        return StreamingResponse(
            storage.stream(clip.storage_key),
            media_type=clip.content_type,
            headers=headers,
        )

    start, end = parsed
    headers["Content-Range"] = f"bytes {start}-{end}/{size}"
    headers["Content-Length"] = str(end - start + 1)
    return StreamingResponse(
        storage.stream(clip.storage_key, start=start, end=end),
        status_code=status.HTTP_206_PARTIAL_CONTENT,
        media_type=clip.content_type,
        headers=headers,
    )


@router.patch("/audio/{clip_id}", response_model=AudioClipOut, summary="Update clip metadata")
async def update_audio(
    clip_id: uuid.UUID, payload: AudioClipUpdate, owner: OwnerDep, session: SessionDep
) -> AudioClipOut:
    clip = await _get_clip(session, owner.id, clip_id)
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(clip, field, value)
    await session.commit()
    await session.refresh(clip)
    return AudioClipOut.model_validate(clip)


@router.delete(
    "/audio/{clip_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Delete a clip",
)
async def delete_audio(
    clip_id: uuid.UUID, owner: OwnerDep, session: SessionDep, storage: StorageDep
) -> Response:
    clip = await _get_clip(session, owner.id, clip_id)
    key = clip.storage_key
    await session.delete(clip)
    await session.commit()
    await storage.delete(key)
    return Response(status_code=status.HTTP_204_NO_CONTENT)

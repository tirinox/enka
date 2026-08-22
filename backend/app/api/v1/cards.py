from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, BackgroundTasks, Query, Response, status
from sqlalchemy import func, select
from sqlalchemy.orm import selectinload

from app.api.deps import OwnerDep, SessionDep, StorageDep
from app.core.errors import ConflictError
from app.core.pagination import Page
from app.models.card import Card
from app.schemas.card import (
    BulkCreateResult,
    CardBulkCreate,
    CardCreate,
    CardOut,
    CardUpdate,
    SearchResponse,
)
from app.schemas.common import CardSort, SortOrder, TagMode
from app.services import cards as card_service
from app.services import search as search_service
from app.services import tts as tts_service

router = APIRouter(prefix="/cards", tags=["cards"])

_LOADERS = (selectinload(Card.tags), selectinload(Card.audio_clips))


@router.get(
    "",
    response_model=Page[CardOut],
    summary="List cards (paginated)",
    description=(
        "The plain browsing mode. Also the sync endpoint: pass `updated_since` "
        "with the `server_time` from your last response and `include_deleted=true` "
        "to receive only what changed, tombstones included."
    ),
)
async def list_cards(
    owner: OwnerDep,
    session: SessionDep,
    q: Annotated[
        str | None, Query(description="Substring filter over term/definition/notes.")
    ] = None,
    tags: Annotated[list[str] | None, Query(description="Repeat for multiple tags.")] = None,
    tag_mode: TagMode = TagMode.ANY,
    has_definition: bool | None = None,
    has_audio: bool | None = None,
    suspended: bool | None = None,
    star_rating: Annotated[int | None, Query(ge=1, le=5)] = None,
    due_before: datetime | None = None,
    updated_since: Annotated[
        datetime | None, Query(description="Delta sync watermark; exclusive.")
    ] = None,
    include_deleted: Annotated[
        bool, Query(description="Include soft-deleted cards as tombstones.")
    ] = False,
    sort: CardSort = CardSort.CREATED_AT,
    order: SortOrder = SortOrder.DESC,
    limit: Annotated[int, Query(ge=1, le=500)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> Page[CardOut]:
    filters = {
        "include_deleted": include_deleted,
        "updated_since": updated_since,
        "tags": tags,
        "tag_mode": tag_mode,
        "has_definition": has_definition,
        "has_audio": has_audio,
        "suspended": suspended,
        "star_rating": star_rating,
        "due_before": due_before,
    }

    count_stmt = card_service.apply_text_filter(
        card_service.apply_filters(select(func.count(Card.id)), owner.id, **filters), q
    )
    total = (await session.execute(count_stmt)).scalar_one()

    stmt = card_service.apply_text_filter(
        card_service.apply_filters(select(Card).options(*_LOADERS), owner.id, **filters), q
    )
    stmt = card_service.apply_sort(stmt, sort, order).limit(limit).offset(offset)
    rows = (await session.execute(stmt)).scalars().unique().all()

    return Page[CardOut](
        items=[card_service.card_to_out(card) for card in rows],
        total=total,
        limit=limit,
        offset=offset,
        has_more=offset + len(rows) < total,
    )


@router.get(
    "/search",
    response_model=SearchResponse,
    summary="Fuzzy search",
    description=(
        "Trigram search that tolerates typos and ignores case and accents. "
        "Check `exact_match` to tell whether the phrase is already in your collection."
    ),
)
async def search(
    owner: OwnerDep,
    session: SessionDep,
    q: Annotated[str, Query(min_length=1, description="What you're looking for.")],
    side: Annotated[str, Query(pattern="^(term|definition|both)$")] = "both",
    limit: Annotated[int, Query(ge=1, le=100)] = 20,
    threshold: Annotated[
        float, Query(ge=0.0, le=1.0, description="Minimum similarity; lower is fuzzier.")
    ] = 0.2,
) -> SearchResponse:
    return await search_service.search_cards(
        session,
        owner.id,
        q,
        side=side,
        limit=limit,
        threshold=threshold,  # type: ignore[arg-type]
    )


@router.post("", response_model=CardOut, status_code=status.HTTP_201_CREATED, summary="Add a card")
async def create_card(
    payload: CardCreate,
    owner: OwnerDep,
    session: SessionDep,
    storage: StorageDep,
    background_tasks: BackgroundTasks,
) -> CardOut:
    card = Card(
        owner_id=owner.id,
        term=payload.term,
        definition=payload.definition,
        notes=payload.notes,
        star_rating=payload.star_rating,
        suspended=payload.suspended,
        srs_step=0,
    )
    if payload.due_at is not None:
        card.due_at = payload.due_at
    card.tags = await card_service.resolve_tags(session, owner.id, payload.tags)

    session.add(card)
    await session.commit()
    await session.refresh(card, ["tags", "audio_clips"])
    # Runs after the response is sent, on this same session — see the note
    # in app/services/tts.py. The card in this response never carries the
    # generated clip; a client sees it on its next fetch, same as it would
    # for any clip attached after the fact.
    background_tasks.add_task(tts_service.generate_term_clip, session, storage, card)
    return card_service.card_to_out(card)


@router.post(
    "/bulk",
    response_model=BulkCreateResult,
    status_code=status.HTTP_201_CREATED,
    summary="Add many cards at once",
    description="For importing a word list. Optionally skips terms you already have.",
)
async def bulk_create(
    payload: CardBulkCreate,
    owner: OwnerDep,
    session: SessionDep,
    storage: StorageDep,
    background_tasks: BackgroundTasks,
    skip_duplicates: Annotated[
        bool, Query(description="Silently skip terms that already exist (case-insensitive).")
    ] = True,
) -> BulkCreateResult:
    existing_terms: set[str] = set()
    if skip_duplicates:
        rows = (
            (
                await session.execute(
                    select(func.lower(func.btrim(Card.term))).where(
                        Card.owner_id == owner.id, Card.deleted_at.is_(None)
                    )
                )
            )
            .scalars()
            .all()
        )
        existing_terms = set(rows)

    created: list[Card] = []
    skipped: list[str] = []
    seen_in_batch: set[str] = set()

    for item in payload.cards:
        key = item.term.strip().lower()
        if skip_duplicates and (key in existing_terms or key in seen_in_batch):
            skipped.append(item.term)
            continue
        seen_in_batch.add(key)

        card = Card(
            owner_id=owner.id,
            term=item.term,
            definition=item.definition,
            notes=item.notes,
            star_rating=item.star_rating,
            suspended=item.suspended,
            srs_step=0,
        )
        if item.due_at is not None:
            card.due_at = item.due_at
        card.tags = await card_service.resolve_tags(session, owner.id, item.tags)
        session.add(card)
        created.append(card)

    await session.commit()
    for card in created:
        await session.refresh(card, ["tags", "audio_clips"])
        # Scheduled one at a time — BackgroundTasks runs them in sequence,
        # so a 1000-card import never pins every core at once.
        background_tasks.add_task(tts_service.generate_term_clip, session, storage, card)

    return BulkCreateResult(
        created=[card_service.card_to_out(c) for c in created],
        skipped_duplicates=skipped,
    )


@router.get("/{card_id}", response_model=CardOut, summary="Get one card")
async def get_card(card_id: uuid.UUID, owner: OwnerDep, session: SessionDep) -> CardOut:
    card = await card_service.get_card(session, owner.id, card_id)
    return card_service.card_to_out(card)


@router.patch(
    "/{card_id}",
    response_model=CardOut,
    summary="Update a card",
    description="Only the fields you send are changed. Sending `tags` replaces the whole set.",
)
async def update_card(
    card_id: uuid.UUID, payload: CardUpdate, owner: OwnerDep, session: SessionDep
) -> CardOut:
    card = await card_service.get_card(session, owner.id, card_id)
    data = payload.model_dump(exclude_unset=True)

    if "tags" in data:
        card.tags = await card_service.resolve_tags(session, owner.id, data.pop("tags") or [])
    for field, value in data.items():
        setattr(card, field, value)

    await session.commit()
    await session.refresh(card, ["tags", "audio_clips"])
    return card_service.card_to_out(card)


@router.delete(
    "/{card_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Delete a card",
    description=(
        "Soft by default: the row survives as a tombstone so your other devices "
        "learn about the deletion on their next sync. `hard=true` purges it and "
        "its audio files immediately."
    ),
)
async def delete_card(
    card_id: uuid.UUID,
    owner: OwnerDep,
    session: SessionDep,
    storage: StorageDep,
    hard: bool = False,
) -> Response:
    card = await card_service.get_card(session, owner.id, card_id, include_deleted=True)

    if hard:
        keys = [clip.storage_key for clip in card.audio_clips]
        await session.delete(card)
        await session.commit()
        # Files last: a failure here leaves an orphan file, which is harmless.
        # The reverse order could leave a row pointing at nothing.
        for key in keys:
            await storage.delete(key)
    else:
        if card.deleted_at is None:
            card.deleted_at = datetime.now(UTC)
            await session.commit()

    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post(
    "/{card_id}/restore",
    response_model=CardOut,
    summary="Undo a soft delete",
)
async def restore_card(card_id: uuid.UUID, owner: OwnerDep, session: SessionDep) -> CardOut:
    card = await card_service.get_card(session, owner.id, card_id, include_deleted=True)
    if card.deleted_at is None:
        raise ConflictError("Card is not deleted.")
    card.deleted_at = None
    await session.commit()
    await session.refresh(card, ["tags", "audio_clips"])
    return card_service.card_to_out(card)

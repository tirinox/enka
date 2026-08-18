from __future__ import annotations

import random
import uuid
from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Query
from sqlalchemy import Select, func, select
from sqlalchemy.orm import selectinload

from app.api.deps import OwnerDep, SessionDep
from app.core.errors import ConflictError, NotFoundError
from app.models.card import Card
from app.models.review_log import ReviewDirection, ReviewLog
from app.schemas.common import TagMode
from app.schemas.study import (
    AnswerRequest,
    AnswerResponse,
    StudyCard,
    StudyDirection,
    StudyMode,
    StudyQueue,
    UndoResponse,
)
from app.services import cards as card_service
from app.services import srs

router = APIRouter(prefix="/study", tags=["study"])

_LOADERS = (selectinload(Card.tags), selectinload(Card.audio_clips))


def _base(owner_id: uuid.UUID, tags: list[str] | None, tag_mode: TagMode) -> Select:
    return card_service.apply_filters(
        select(Card).options(*_LOADERS),
        owner_id,
        tags=tags,
        tag_mode=tag_mode,
        suspended=False,
    )


def _ordered_for(mode: StudyMode, stmt: Select, now: datetime) -> Select:
    """Turn a filtered card query into a study queue for one mode."""
    if mode is StudyMode.DUE:
        return stmt.where(Card.due_at <= now).order_by(Card.due_at.asc())
    if mode is StudyMode.NEW:
        return stmt.where(Card.last_review_at.is_(None)).order_by(Card.created_at.asc())
    if mode is StudyMode.REINFORCE:
        # Worst-remembered first: what you've forgotten most often, then what
        # the model thinks is most fragile. Unstudied cards sort last — this
        # mode is about shoring up shaky knowledge, not meeting new words.
        return stmt.order_by(Card.lapses.desc(), Card.stability.asc().nullslast())
    if mode is StudyMode.RANDOM:
        return stmt.order_by(func.random())
    raise ValueError(f"{mode} has no ordering of its own")


#: What `smart` walks through: catch up on what's due, then meet new words,
#: then drill the weak ones if you're still going.
_SMART_CHAIN = (StudyMode.DUE, StudyMode.NEW, StudyMode.REINFORCE)


async def _pick(
    session: SessionDep,
    owner_id: uuid.UUID,
    mode: StudyMode,
    tags: list[str] | None,
    tag_mode: TagMode,
    now: datetime,
    limit: int,
) -> tuple[list[Card], StudyMode]:
    chain = _SMART_CHAIN if mode is StudyMode.SMART else (mode,)
    for candidate in chain:
        stmt = _ordered_for(candidate, _base(owner_id, tags, tag_mode), now).limit(limit)
        rows = (await session.execute(stmt)).scalars().unique().all()
        if rows:
            return list(rows), candidate
    return [], mode


async def _due_count(session: SessionDep, owner_id: uuid.UUID, now: datetime) -> int:
    return (
        await session.execute(
            card_service.apply_filters(
                select(func.count(Card.id)), owner_id, suspended=False
            ).where(Card.due_at <= now)
        )
    ).scalar_one()


def _resolve_direction(card: Card, requested: StudyDirection) -> ReviewDirection:
    """Pick which side to show.

    A card with no definition yet can only be asked term-first — there is
    nothing on the other side to prompt with.
    """
    if not card.definition or not card.definition.strip():
        return ReviewDirection.TERM_TO_DEF
    if requested is StudyDirection.RANDOM:
        return random.choice([ReviewDirection.TERM_TO_DEF, ReviewDirection.DEF_TO_TERM])
    return ReviewDirection(requested.value)


def _humanize(seconds: float) -> str:
    if seconds < 90:
        return f"{round(seconds)} seconds"
    minutes = seconds / 60
    if minutes < 90:
        return f"{round(minutes)} minutes"
    hours = minutes / 60
    if hours < 36:
        return f"{round(hours)} hours"
    days = hours / 24
    if days < 60:
        return f"{round(days)} days"
    months = days / 30.44
    if months < 24:
        return f"{round(months)} months"
    return f"{days / 365.25:.1f} years"


@router.get(
    "/next",
    response_model=StudyCard,
    summary="Get the next card to study",
    description=(
        "Marks the card as shown (`times_shown`, `last_shown_at`) — pass "
        "`mark_shown=false` to peek without counting it."
    ),
)
async def next_card(
    owner: OwnerDep,
    session: SessionDep,
    mode: StudyMode = StudyMode.SMART,
    direction: StudyDirection = StudyDirection.TERM_TO_DEF,
    tags: Annotated[list[str] | None, Query()] = None,
    tag_mode: TagMode = TagMode.ANY,
    mark_shown: bool = True,
) -> StudyCard:
    now = datetime.now(UTC)
    rows, used_mode = await _pick(session, owner.id, mode, tags, tag_mode, now, limit=1)
    if not rows:
        raise NotFoundError(
            "Nothing to study with those filters.",
            {"mode": mode.value, "tags": tags or []},
        )

    card = rows[0]
    if mark_shown:
        card.times_shown += 1
        card.last_shown_at = now
        await session.commit()
        await session.refresh(card, ["tags", "audio_clips"])

    return StudyCard(
        card=card_service.card_to_out(card),
        direction=_resolve_direction(card, direction),
        mode=used_mode,
        remaining_due=await _due_count(session, owner.id, now),
    )


@router.get(
    "/queue",
    response_model=StudyQueue,
    summary="Prefetch a batch of cards",
    description="Does not mark anything as shown — intended for offline buffering.",
)
async def queue(
    owner: OwnerDep,
    session: SessionDep,
    mode: StudyMode = StudyMode.SMART,
    direction: StudyDirection = StudyDirection.TERM_TO_DEF,
    tags: Annotated[list[str] | None, Query()] = None,
    tag_mode: TagMode = TagMode.ANY,
    limit: Annotated[int, Query(ge=1, le=200)] = 20,
) -> StudyQueue:
    now = datetime.now(UTC)
    rows, used_mode = await _pick(session, owner.id, mode, tags, tag_mode, now, limit=limit)
    remaining = await _due_count(session, owner.id, now)
    return StudyQueue(
        items=[
            StudyCard(
                card=card_service.card_to_out(card),
                direction=_resolve_direction(card, direction),
                mode=used_mode,
                remaining_due=remaining,
            )
            for card in rows
        ],
        remaining_due=remaining,
    )


@router.post(
    "/{card_id}/answer",
    response_model=AnswerResponse,
    summary="Record how well you remembered",
    description=(
        "`again` = didn't remember at all (comes back in about a minute), "
        "`hard`, `good`, `easy` push it progressively further out."
    ),
)
async def answer(
    card_id: uuid.UUID,
    payload: AnswerRequest,
    owner: OwnerDep,
    session: SessionDep,
) -> AnswerResponse:
    card = await card_service.get_card(session, owner.id, card_id)
    reviewed_at = (payload.reviewed_at or datetime.now(UTC)).astimezone(UTC)

    log = srs.review(
        card,
        srs.RATING_BY_NAME[payload.rating.value],
        reviewed_at=reviewed_at,
        direction=payload.direction,
        elapsed_ms=payload.elapsed_ms,
    )
    session.add(log)
    await session.commit()
    await session.refresh(card, ["tags", "audio_clips"])

    interval = (card.due_at - reviewed_at).total_seconds()
    return AnswerResponse(
        card=card_service.card_to_out(card),
        review_id=log.id,
        interval_seconds=interval,
        interval_human=_humanize(interval),
        remaining_due=await _due_count(session, owner.id, datetime.now(UTC)),
    )


@router.post(
    "/{card_id}/undo",
    response_model=UndoResponse,
    summary="Undo the last answer",
    description="Restores the card's exact scheduling state from before the most recent review.",
)
async def undo(card_id: uuid.UUID, owner: OwnerDep, session: SessionDep) -> UndoResponse:
    card = await card_service.get_card(session, owner.id, card_id)
    log = (
        await session.execute(
            select(ReviewLog)
            .where(
                ReviewLog.card_id == card.id,
                ReviewLog.owner_id == owner.id,
                ReviewLog.undone_at.is_(None),
            )
            .order_by(ReviewLog.reviewed_at.desc())
            .limit(1)
        )
    ).scalar_one_or_none()
    if log is None:
        raise ConflictError("This card has no review to undo.")

    srs.undo(card, log)
    await session.commit()
    await session.refresh(card, ["tags", "audio_clips"])
    return UndoResponse(card=card_service.card_to_out(card), undone_review_id=log.id)

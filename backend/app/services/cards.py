from __future__ import annotations

import uuid
from collections.abc import Iterable, Sequence

from sqlalchemy import Select, and_, exists, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import NotFoundError
from app.models.audio_clip import AudioClip
from app.models.card import Card, SrsState
from app.models.tag import Tag, card_tag
from app.schemas.audio import AudioClipOut
from app.schemas.card import CardOut
from app.schemas.common import CardSort, SortOrder, TagMode
from app.services import srs


def card_to_out(card: Card) -> CardOut:
    return CardOut(
        id=card.id,
        term=card.term,
        definition=card.definition,
        notes=card.notes,
        tags=[tag.name for tag in card.tags],
        star_rating=card.star_rating,
        suspended=card.suspended,
        created_at=card.created_at,
        updated_at=card.updated_at,
        deleted_at=card.deleted_at,
        last_shown_at=card.last_shown_at,
        first_studied_at=card.first_studied_at,
        times_shown=card.times_shown,
        correct_count=card.correct_count,
        wrong_count=card.wrong_count,
        lapses=card.lapses,
        accuracy=card.accuracy,
        srs_state=SrsState(card.srs_state),
        stability=card.stability,
        difficulty=card.difficulty,
        due_at=card.due_at,
        last_review_at=card.last_review_at,
        retrievability=srs.retrievability(card),
        audio_clips=[AudioClipOut.model_validate(clip) for clip in card.audio_clips],
    )


async def resolve_tags(
    session: AsyncSession, owner_id: uuid.UUID, names: Iterable[str]
) -> list[Tag]:
    """Map tag names to rows, creating any that don't exist yet.

    Get-or-create keeps the client simple: it posts ``tags: ["verbs"]`` and
    never has to manage tag lifecycles itself.
    """
    normalized: dict[str, str] = {}
    for raw in names:
        cleaned = " ".join(raw.split())
        if not cleaned:
            continue
        normalized.setdefault(Tag.normalize(cleaned), cleaned)
    if not normalized:
        return []

    existing = (
        (
            await session.execute(
                select(Tag).where(
                    Tag.owner_id == owner_id, Tag.name_normalized.in_(list(normalized))
                )
            )
        )
        .scalars()
        .all()
    )

    by_norm = {tag.name_normalized: tag for tag in existing}
    for norm, display in normalized.items():
        if norm not in by_norm:
            tag = Tag(owner_id=owner_id, name=display[:64], name_normalized=norm[:64])
            session.add(tag)
            by_norm[norm] = tag
    # Assign ids before the caller associates them with a card.
    await session.flush()
    return [by_norm[norm] for norm in normalized]


async def get_card(
    session: AsyncSession,
    owner_id: uuid.UUID,
    card_id: uuid.UUID,
    *,
    include_deleted: bool = False,
) -> Card:
    stmt = select(Card).where(Card.id == card_id, Card.owner_id == owner_id)
    if not include_deleted:
        stmt = stmt.where(Card.deleted_at.is_(None))
    card = (await session.execute(stmt)).scalar_one_or_none()
    if card is None:
        raise NotFoundError(f"No card with id {card_id}.")
    return card


def apply_filters(
    stmt: Select,
    owner_id: uuid.UUID,
    *,
    include_deleted: bool = False,
    updated_since=None,
    tags: Sequence[str] | None = None,
    tag_mode: TagMode = TagMode.ANY,
    has_definition: bool | None = None,
    has_audio: bool | None = None,
    suspended: bool | None = None,
    star_rating: int | None = None,
    due_before=None,
) -> Select:
    stmt = stmt.where(Card.owner_id == owner_id)

    if not include_deleted:
        stmt = stmt.where(Card.deleted_at.is_(None))
    if updated_since is not None:
        stmt = stmt.where(Card.updated_at > updated_since)
    if suspended is not None:
        stmt = stmt.where(Card.suspended.is_(suspended))
    if star_rating is not None:
        stmt = stmt.where(Card.star_rating == star_rating)
    if due_before is not None:
        stmt = stmt.where(Card.due_at <= due_before)

    if has_definition is not None:
        has_def = and_(Card.definition.is_not(None), func.btrim(Card.definition) != "")
        stmt = stmt.where(has_def if has_definition else ~has_def)

    if has_audio is not None:
        clause = exists().where(AudioClip.card_id == Card.id)
        stmt = stmt.where(clause if has_audio else ~clause)

    if tags:
        normalized = [Tag.normalize(t) for t in tags if t.strip()]
        if normalized:
            match = (
                select(func.count(func.distinct(Tag.id)))
                .select_from(card_tag.join(Tag, Tag.id == card_tag.c.tag_id))
                .where(card_tag.c.card_id == Card.id, Tag.name_normalized.in_(normalized))
                .scalar_subquery()
            )
            stmt = stmt.where(match >= (len(set(normalized)) if tag_mode is TagMode.ALL else 1))

    return stmt


def apply_text_filter(stmt: Select, q: str | None) -> Select:
    """Cheap substring filter for the list endpoint.

    This is not the fuzzy search — see ``services.search`` for that. Here we
    only want "narrow the list to rows containing this", which a plain ILIKE
    expresses more predictably than a similarity ranking.
    """
    if not q or not q.strip():
        return stmt
    pattern = f"%{q.strip()}%"
    return stmt.where(
        or_(
            Card.term.ilike(pattern),
            Card.definition.ilike(pattern),
            Card.notes.ilike(pattern),
        )
    )


_SORT_COLUMNS = {
    CardSort.CREATED_AT: Card.created_at,
    CardSort.UPDATED_AT: Card.updated_at,
    CardSort.DUE_AT: Card.due_at,
    CardSort.TERM: Card.term,
    CardSort.TIMES_SHOWN: Card.times_shown,
    CardSort.STAR_RATING: Card.star_rating,
}


def apply_sort(stmt: Select, sort: CardSort, order: SortOrder) -> Select:
    column = _SORT_COLUMNS[sort]
    direction = column.asc() if order is SortOrder.ASC else column.desc()
    # id as the tiebreaker keeps pagination stable when timestamps collide,
    # which they do constantly during a bulk import.
    return stmt.order_by(direction.nullslast(), Card.id.asc())

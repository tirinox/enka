from __future__ import annotations

import itertools
import uuid
from datetime import UTC, date, datetime, timedelta

from sqlalchemy import Integer, and_, case, exists, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.audio_clip import AudioClip
from app.models.card import Card, SrsState
from app.models.review_log import ReviewLog
from app.models.tag import Tag
from app.schemas.stats import (
    CollectionStats,
    DailyActivity,
    HeatmapDay,
    HeatmapResponse,
    LeechCard,
    ScheduleStats,
    StatsResponse,
    StudyStats,
)

_ACTIVE = Card.deleted_at.is_(None)


def _count_if(condition) -> object:
    return func.count(case((condition, 1)))


async def collect_stats(
    session: AsyncSession, owner_id: uuid.UUID, *, leech_limit: int = 10
) -> StatsResponse:
    now = datetime.now(UTC)
    end_of_today = datetime.combine(now.date(), datetime.max.time(), tzinfo=UTC)

    has_definition = and_(Card.definition.is_not(None), func.btrim(Card.definition) != "")
    has_audio = exists().where(AudioClip.card_id == Card.id)

    card_row = (
        await session.execute(
            select(
                func.count().label("total"),
                _count_if(~has_definition).label("without_definition"),
                _count_if(has_audio).label("with_audio"),
                _count_if(Card.suspended.is_(True)).label("suspended"),
                _count_if(Card.times_shown > 0).label("studied_unique"),
                _count_if(Card.times_shown == 0).label("never_studied"),
                func.coalesce(func.sum(Card.times_shown), 0).label("total_shows"),
                func.coalesce(func.sum(Card.correct_count), 0).label("correct"),
                func.coalesce(func.sum(Card.wrong_count), 0).label("wrong"),
                _count_if(and_(Card.due_at <= now, Card.suspended.is_(False))).label("due_now"),
                _count_if(and_(Card.due_at <= end_of_today, Card.suspended.is_(False))).label(
                    "due_today"
                ),
                _count_if(Card.last_review_at.is_(None)).label("new_count"),
                _count_if(Card.srs_state == SrsState.LEARNING).label("learning"),
                _count_if(Card.srs_state == SrsState.REVIEW).label("review"),
                _count_if(Card.srs_state == SrsState.RELEARNING).label("relearning"),
                func.avg(Card.stability).label("avg_stability"),
                func.avg(Card.difficulty).label("avg_difficulty"),
                func.avg(Card.star_rating.cast(Integer)).label("avg_star"),
            ).where(Card.owner_id == owner_id, _ACTIVE)
        )
    ).one()

    total_tags = (
        await session.execute(select(func.count()).select_from(Tag).where(Tag.owner_id == owner_id))
    ).scalar_one()

    total_reviews = (
        await session.execute(
            select(func.count())
            .select_from(ReviewLog)
            .where(ReviewLog.owner_id == owner_id, ReviewLog.undone_at.is_(None))
        )
    ).scalar_one()

    correct = int(card_row.correct or 0)
    wrong = int(card_row.wrong or 0)
    answered = correct + wrong

    daily = await _daily_activity(session, owner_id, since=now - timedelta(days=30))
    all_days = await _review_days(session, owner_id)
    current_streak, longest_streak = _streaks(all_days, today=now.date())
    leeches = await _leeches(session, owner_id, limit=leech_limit)

    return StatsResponse(
        collection=CollectionStats(
            total_cards=card_row.total,
            cards_without_definition=card_row.without_definition,
            cards_with_audio=card_row.with_audio,
            suspended_cards=card_row.suspended,
            total_tags=total_tags,
        ),
        study=StudyStats(
            studied_unique=card_row.studied_unique,
            never_studied=card_row.never_studied,
            total_shows=int(card_row.total_shows or 0),
            total_reviews=total_reviews,
            correct=correct,
            wrong=wrong,
            accuracy=(correct / answered) if answered else None,
        ),
        schedule=ScheduleStats(
            due_now=card_row.due_now,
            due_today=card_row.due_today,
            new_count=card_row.new_count,
            learning=card_row.learning,
            review=card_row.review,
            relearning=card_row.relearning,
            avg_stability_days=_maybe_float(card_row.avg_stability),
            avg_difficulty=_maybe_float(card_row.avg_difficulty),
            avg_star_rating=_maybe_float(card_row.avg_star),
        ),
        reviews_last_30_days=daily,
        current_streak_days=current_streak,
        longest_streak_days=longest_streak,
        leeches=leeches,
        server_time=now,
    )


def _maybe_float(value: object) -> float | None:
    return None if value is None else round(float(value), 4)  # type: ignore[arg-type]


async def _daily_activity(
    session: AsyncSession, owner_id: uuid.UUID, *, since: datetime
) -> list[DailyActivity]:
    day = func.date_trunc("day", func.timezone("UTC", ReviewLog.reviewed_at))
    rows = (
        await session.execute(
            select(
                day.label("day"),
                func.count().label("reviews"),
                _count_if(ReviewLog.rating > 1).label("correct"),
            )
            .where(
                ReviewLog.owner_id == owner_id,
                ReviewLog.undone_at.is_(None),
                ReviewLog.reviewed_at >= since,
            )
            .group_by(day)
            .order_by(day)
        )
    ).all()
    return [
        DailyActivity(day=row.day.date(), reviews=row.reviews, correct=row.correct) for row in rows
    ]


async def _review_days(session: AsyncSession, owner_id: uuid.UUID) -> list[date]:
    day = func.date_trunc("day", func.timezone("UTC", ReviewLog.reviewed_at))
    rows = (
        await session.execute(
            select(day.label("day"))
            .where(ReviewLog.owner_id == owner_id, ReviewLog.undone_at.is_(None))
            .group_by(day)
            .order_by(day)
        )
    ).all()
    return [row.day.date() for row in rows]


def _streaks(days: list[date], *, today: date) -> tuple[int, int]:
    """Current and longest run of consecutive days with at least one review.

    The current streak counts back from today, but a study session that hasn't
    happened *yet today* shouldn't reset it — so yesterday also anchors it.
    """
    if not days:
        return 0, 0

    unique = sorted(set(days))
    longest = run = 1
    for prev, cur in itertools.pairwise(unique):
        run = run + 1 if (cur - prev).days == 1 else 1
        longest = max(longest, run)

    current = 0
    if (today - unique[-1]).days <= 1:
        current = 1
        for i in range(len(unique) - 1, 0, -1):
            if (unique[i] - unique[i - 1]).days != 1:
                break
            current += 1
    return current, longest


async def _leeches(session: AsyncSession, owner_id: uuid.UUID, *, limit: int) -> list[LeechCard]:
    rows = (
        (
            await session.execute(
                select(Card)
                .where(Card.owner_id == owner_id, _ACTIVE, Card.lapses > 0)
                .order_by(Card.lapses.desc(), Card.wrong_count.desc())
                .limit(limit)
            )
        )
        .scalars()
        .all()
    )
    return [
        LeechCard(
            id=card.id,
            term=card.term,
            definition=card.definition,
            lapses=card.lapses,
            wrong_count=card.wrong_count,
            accuracy=card.accuracy,
        )
        for card in rows
    ]


async def collect_heatmap(
    session: AsyncSession, owner_id: uuid.UUID, *, days: int
) -> HeatmapResponse:
    since = datetime.now(UTC) - timedelta(days=days)
    activity = await _daily_activity(session, owner_id, since=since)
    entries = [HeatmapDay(day=item.day, reviews=item.reviews) for item in activity]
    return HeatmapResponse(
        days=entries,
        max_reviews=max((e.reviews for e in entries), default=0),
        total_reviews=sum(e.reviews for e in entries),
    )

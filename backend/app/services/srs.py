"""The only module that knows about the ``fsrs`` package.

Everything else deals in our own ORM columns. Keeping the mapping in one place
means a library upgrade is reviewed here and nowhere else — and the round-trip
test in ``tests/test_srs.py`` pins the translation so a signature change can't
silently corrupt everyone's scheduling.
"""

from __future__ import annotations

import functools
from datetime import UTC, datetime, timedelta

from fsrs import Card as FsrsCard
from fsrs import Rating, Scheduler, State

from app.core.config import settings
from app.models.card import Card, SrsState
from app.models.review_log import ReviewDirection, ReviewLog

#: Client-facing rating names. `again` is the "I don't remember this at all,
#: show it again soon" answer; it is the only one counted as a wrong answer.
RATING_BY_NAME: dict[str, Rating] = {
    "again": Rating.Again,
    "hard": Rating.Hard,
    "good": Rating.Good,
    "easy": Rating.Easy,
}
NAME_BY_RATING: dict[int, str] = {int(v): k for k, v in RATING_BY_NAME.items()}


@functools.lru_cache
def get_scheduler() -> Scheduler:
    return Scheduler(
        desired_retention=settings.fsrs_desired_retention,
        learning_steps=tuple(timedelta(minutes=m) for m in settings.fsrs_learning_steps_minutes),
        relearning_steps=tuple(
            timedelta(minutes=m) for m in settings.fsrs_relearning_steps_minutes
        ),
        maximum_interval=settings.fsrs_maximum_interval,
        enable_fuzzing=settings.fsrs_enable_fuzzing,
    )


def _fsrs_card_id(card: Card) -> int:
    """A stable int id for the library, derived from our UUID.

    FSRS only uses ``card_id`` for bookkeeping — it does not feed scheduling or
    the interval fuzz — but keeping it stable makes review logs exported for the
    optimiser line up with the right card.
    """
    return card.id.int % (2**62)


def to_fsrs_card(card: Card) -> FsrsCard:
    return FsrsCard(
        card_id=_fsrs_card_id(card),
        state=State(card.srs_state),
        step=card.srs_step,
        stability=card.stability,
        difficulty=card.difficulty,
        due=card.due_at.astimezone(UTC),
        last_review=card.last_review_at.astimezone(UTC) if card.last_review_at else None,
    )


def write_back(card: Card, fsrs_card: FsrsCard) -> None:
    """Copy scheduler output onto the ORM row."""
    card.srs_state = int(fsrs_card.state)
    card.srs_step = fsrs_card.step
    card.stability = fsrs_card.stability
    card.difficulty = fsrs_card.difficulty
    card.due_at = fsrs_card.due
    card.last_review_at = fsrs_card.last_review


def retrievability(card: Card, at: datetime | None = None) -> float | None:
    """Current probability of recalling this card. ``None`` before first review."""
    if card.last_review_at is None or card.stability is None:
        return None
    return get_scheduler().get_card_retrievability(to_fsrs_card(card), current_datetime=at)


def review(
    card: Card,
    rating: Rating,
    *,
    reviewed_at: datetime | None = None,
    direction: ReviewDirection | None = None,
    elapsed_ms: int | None = None,
) -> ReviewLog:
    """Apply one answer: reschedule the card, update tallies, return the log row.

    The caller is responsible for adding the returned ``ReviewLog`` to the
    session and committing — this function only mutates ``card`` in memory.
    """
    now = (reviewed_at or datetime.now(UTC)).astimezone(UTC)

    log = ReviewLog(
        owner_id=card.owner_id,
        card_id=card.id,
        reviewed_at=now,
        rating=int(rating),
        direction=direction,
        elapsed_ms=elapsed_ms,
        prev_state=card.srs_state,
        prev_step=card.srs_step,
        prev_stability=card.stability,
        prev_difficulty=card.difficulty,
        prev_due_at=card.due_at,
        prev_last_review_at=card.last_review_at,
    )

    was_review_state = card.srs_state == SrsState.REVIEW

    updated, _ = get_scheduler().review_card(
        to_fsrs_card(card),
        rating,
        review_datetime=now,
        review_duration=elapsed_ms,
    )
    write_back(card, updated)

    if rating is Rating.Again:
        card.wrong_count += 1
        # A lapse is specifically forgetting something you had already learned,
        # which is what makes it worth surfacing as a "leech" later.
        if was_review_state:
            card.lapses += 1
    else:
        card.correct_count += 1

    if card.first_studied_at is None:
        card.first_studied_at = now

    log.new_state = card.srs_state
    log.new_stability = card.stability
    log.new_difficulty = card.difficulty
    log.new_due_at = card.due_at
    return log


def undo(card: Card, log: ReviewLog) -> None:
    """Restore the exact pre-review state captured in ``log``."""
    card.srs_state = log.prev_state if log.prev_state is not None else int(SrsState.LEARNING)
    card.srs_step = log.prev_step
    card.stability = log.prev_stability
    card.difficulty = log.prev_difficulty
    if log.prev_due_at is not None:
        card.due_at = log.prev_due_at
    card.last_review_at = log.prev_last_review_at

    if log.rating == int(Rating.Again):
        card.wrong_count = max(0, card.wrong_count - 1)
        if log.prev_state == int(SrsState.REVIEW):
            card.lapses = max(0, card.lapses - 1)
    else:
        card.correct_count = max(0, card.correct_count - 1)

    log.undone_at = datetime.now(UTC)

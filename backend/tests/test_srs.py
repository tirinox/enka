"""Unit tests for the FSRS adapter.

These touch no database and no HTTP. They pin the translation between our
columns and the ``fsrs`` library, which is the one place where a dependency
upgrade could silently corrupt everyone's review schedule.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from fsrs import Rating, State

from app.models.card import Card, SrsState
from app.models.review_log import ReviewDirection
from app.services import srs


def make_card(**overrides) -> Card:
    """A detached Card with the defaults a freshly created row would have.

    Built by hand rather than through the ORM because these tests deliberately
    avoid the database.
    """
    card = Card(
        id=uuid.uuid4(),
        owner_id=uuid.uuid4(),
        term="das Fenster",
        definition="window",
        srs_state=int(SrsState.LEARNING),
        srs_step=0,
        stability=None,
        difficulty=None,
        due_at=datetime.now(UTC),
        last_review_at=None,
        times_shown=0,
        correct_count=0,
        wrong_count=0,
        lapses=0,
        first_studied_at=None,
    )
    for key, value in overrides.items():
        setattr(card, key, value)
    return card


# ------------------------------------------------------------- round trip ---
def test_new_card_maps_to_a_new_fsrs_card():
    card = make_card()
    fsrs_card = srs.to_fsrs_card(card)

    assert fsrs_card.state is State.Learning
    assert fsrs_card.stability is None
    assert fsrs_card.difficulty is None
    assert fsrs_card.last_review is None


def test_state_survives_a_round_trip():
    """to_fsrs_card -> write_back must be lossless, or reviews drift."""
    original = make_card(
        srs_state=int(SrsState.REVIEW),
        srs_step=None,
        stability=12.5,
        difficulty=6.25,
        due_at=datetime(2026, 9, 1, 12, 0, tzinfo=UTC),
        last_review_at=datetime(2026, 8, 20, 12, 0, tzinfo=UTC),
    )
    restored = make_card()
    srs.write_back(restored, srs.to_fsrs_card(original))

    assert restored.srs_state == original.srs_state
    assert restored.srs_step == original.srs_step
    assert restored.stability == pytest.approx(original.stability)
    assert restored.difficulty == pytest.approx(original.difficulty)
    assert restored.due_at == original.due_at
    assert restored.last_review_at == original.last_review_at


def test_fsrs_card_id_is_stable_and_in_range():
    card = make_card()
    assert srs.to_fsrs_card(card).card_id == srs.to_fsrs_card(card).card_id
    assert 0 <= srs._fsrs_card_id(card) < 2**62


# --------------------------------------------------------------- ratings ----
def test_again_brings_the_card_back_within_minutes():
    card = make_card()
    now = datetime.now(UTC)

    srs.review(card, Rating.Again, reviewed_at=now)

    assert card.due_at - now < timedelta(minutes=5)
    assert card.wrong_count == 1
    assert card.correct_count == 0


def test_easy_pushes_the_card_days_out():
    card = make_card()
    now = datetime.now(UTC)

    srs.review(card, Rating.Easy, reviewed_at=now)

    assert card.due_at - now > timedelta(days=1)
    assert card.correct_count == 1
    assert card.wrong_count == 0
    assert card.srs_state == int(SrsState.REVIEW)


@pytest.mark.parametrize(
    ("worse", "better"),
    [(Rating.Again, Rating.Hard), (Rating.Hard, Rating.Good), (Rating.Good, Rating.Easy)],
)
def test_better_ratings_schedule_further_out(worse, better):
    """The property that makes the whole thing a study aid rather than a list."""
    now = datetime.now(UTC)

    worse_card = make_card()
    srs.review(worse_card, worse, reviewed_at=now)

    better_card = make_card()
    srs.review(better_card, better, reviewed_at=now)

    assert better_card.due_at > worse_card.due_at


def test_answering_records_stability_and_difficulty():
    card = make_card()
    srs.review(card, Rating.Good)

    assert card.stability is not None and card.stability > 0
    assert card.difficulty is not None and 1 <= card.difficulty <= 10
    assert card.last_review_at is not None


def test_first_studied_at_is_set_once():
    card = make_card()
    first = datetime(2026, 8, 1, tzinfo=UTC)

    srs.review(card, Rating.Good, reviewed_at=first)
    srs.review(card, Rating.Good, reviewed_at=first + timedelta(days=1))

    assert card.first_studied_at == first


def test_forgetting_a_learned_card_counts_as_a_lapse():
    card = make_card(srs_state=int(SrsState.REVIEW), srs_step=None, stability=30.0, difficulty=5.0)
    srs.review(card, Rating.Again)
    assert card.lapses == 1


def test_forgetting_a_card_still_being_learned_is_not_a_lapse():
    """A lapse means losing something you had learned — not fumbling a new word."""
    card = make_card(srs_state=int(SrsState.LEARNING))
    srs.review(card, Rating.Again)
    assert card.lapses == 0


# ------------------------------------------------------------- review log ---
def test_review_log_captures_both_sides_of_the_change():
    card = make_card(srs_state=int(SrsState.REVIEW), srs_step=None, stability=10.0, difficulty=5.0)
    before_due = card.due_at

    log = srs.review(card, Rating.Good, direction=ReviewDirection.DEF_TO_TERM, elapsed_ms=2500)

    assert log.rating == int(Rating.Good)
    assert log.direction is ReviewDirection.DEF_TO_TERM
    assert log.elapsed_ms == 2500
    assert log.prev_stability == 10.0
    assert log.prev_due_at == before_due
    assert log.new_due_at == card.due_at
    assert log.new_stability == card.stability


# ------------------------------------------------------------------ undo ----
def test_undo_restores_the_exact_previous_state():
    card = make_card(
        srs_state=int(SrsState.REVIEW),
        srs_step=None,
        stability=20.0,
        difficulty=4.0,
        due_at=datetime(2026, 9, 1, tzinfo=UTC),
        last_review_at=datetime(2026, 8, 1, tzinfo=UTC),
        correct_count=3,
        wrong_count=1,
        lapses=1,
    )
    snapshot = (
        card.srs_state,
        card.stability,
        card.difficulty,
        card.due_at,
        card.last_review_at,
        card.correct_count,
        card.wrong_count,
        card.lapses,
    )

    log = srs.review(card, Rating.Again)
    assert card.lapses == 2

    srs.undo(card, log)

    assert (
        card.srs_state,
        card.stability,
        card.difficulty,
        card.due_at,
        card.last_review_at,
        card.correct_count,
        card.wrong_count,
        card.lapses,
    ) == snapshot
    assert log.undone_at is not None


def test_undo_of_a_correct_answer_decrements_the_right_counter():
    card = make_card(correct_count=2, wrong_count=1)
    log = srs.review(card, Rating.Good)
    assert card.correct_count == 3

    srs.undo(card, log)
    assert card.correct_count == 2
    assert card.wrong_count == 1


def test_undo_never_drives_counters_negative():
    card = make_card(correct_count=0, wrong_count=0)
    log = srs.review(card, Rating.Good)
    srs.undo(card, log)
    srs.undo(card, log)  # a second undo is nonsense, but must not corrupt data
    assert card.correct_count == 0
    assert card.wrong_count == 0


# -------------------------------------------------------- retrievability ----
def test_retrievability_is_unknown_before_the_first_review():
    assert srs.retrievability(make_card()) is None


def test_retrievability_decays_over_time():
    card = make_card()
    reviewed = datetime.now(UTC)
    srs.review(card, Rating.Good, reviewed_at=reviewed)

    soon = srs.retrievability(card, at=reviewed + timedelta(hours=1))
    later = srs.retrievability(card, at=reviewed + timedelta(days=30))

    assert 0.0 <= later < soon <= 1.0


def test_rating_names_cover_the_public_api():
    assert set(srs.RATING_BY_NAME) == {"again", "hard", "good", "easy"}
    assert srs.NAME_BY_RATING[int(Rating.Again)] == "again"

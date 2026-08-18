from __future__ import annotations

from datetime import UTC, date, datetime, timedelta

import pytest

from app.services.stats import _streaks


# --------------------------------------------------------------- streaks ----
def test_no_activity_means_no_streak():
    assert _streaks([], today=date(2026, 8, 18)) == (0, 0)


def test_studying_today_starts_a_streak():
    assert _streaks([date(2026, 8, 18)], today=date(2026, 8, 18)) == (1, 1)


def test_consecutive_days_accumulate():
    days = [date(2026, 8, 16), date(2026, 8, 17), date(2026, 8, 18)]
    assert _streaks(days, today=date(2026, 8, 18)) == (3, 3)


def test_yesterday_still_counts_so_a_late_start_today_is_not_punished():
    days = [date(2026, 8, 16), date(2026, 8, 17)]
    assert _streaks(days, today=date(2026, 8, 18)) == (2, 2)


def test_a_two_day_gap_breaks_the_current_streak():
    days = [date(2026, 8, 10), date(2026, 8, 11), date(2026, 8, 12)]
    current, longest = _streaks(days, today=date(2026, 8, 18))
    assert current == 0
    assert longest == 3


def test_longest_streak_is_remembered_after_a_break():
    days = [
        date(2026, 8, 1),
        date(2026, 8, 2),
        date(2026, 8, 3),
        date(2026, 8, 4),
        date(2026, 8, 17),
        date(2026, 8, 18),
    ]
    assert _streaks(days, today=date(2026, 8, 18)) == (2, 4)


def test_duplicate_days_are_not_double_counted():
    days = [date(2026, 8, 17), date(2026, 8, 17), date(2026, 8, 18)]
    assert _streaks(days, today=date(2026, 8, 18)) == (2, 2)


# ------------------------------------------------------------ collection ----
async def test_empty_collection_reports_zeroes(client):
    body = (await client.get("/api/v1/stats")).json()
    assert body["collection"]["total_cards"] == 0
    assert body["study"]["accuracy"] is None
    assert body["current_streak_days"] == 0
    assert body["leeches"] == []


async def test_collection_counts(client, card_factory, wav_bytes):
    await card_factory("with def", "yes", tags=["a"])
    await card_factory("without def")
    suspended = await card_factory("suspended", "x")
    await client.patch(f"/api/v1/cards/{suspended['id']}", json={"suspended": True})

    with_audio = await card_factory("audible", "sound")
    await client.post(
        f"/api/v1/cards/{with_audio['id']}/audio?side=term",
        files={"file": ("a.wav", wav_bytes, "audio/wav")},
    )

    body = (await client.get("/api/v1/stats")).json()
    assert body["collection"]["total_cards"] == 4
    assert body["collection"]["cards_without_definition"] == 1
    assert body["collection"]["cards_with_audio"] == 1
    assert body["collection"]["suspended_cards"] == 1
    assert body["collection"]["total_tags"] == 1


async def test_deleted_cards_are_excluded_from_stats(client, card_factory):
    card = await card_factory("temporary")
    await client.delete(f"/api/v1/cards/{card['id']}")

    body = (await client.get("/api/v1/stats")).json()
    assert body["collection"]["total_cards"] == 0


# ----------------------------------------------------------------- study ----
async def test_study_counters_reflect_answers(client, card_factory):
    good = await card_factory("remembered", "a")
    bad = await card_factory("forgotten", "b")

    await client.post(f"/api/v1/study/{good['id']}/answer", json={"rating": "good"})
    await client.post(f"/api/v1/study/{bad['id']}/answer", json={"rating": "again"})
    await client.post(f"/api/v1/study/{bad['id']}/answer", json={"rating": "again"})

    body = (await client.get("/api/v1/stats")).json()
    assert body["study"]["total_reviews"] == 3
    assert body["study"]["correct"] == 1
    assert body["study"]["wrong"] == 2
    assert body["study"]["accuracy"] == pytest.approx(1 / 3)


async def test_shown_and_studied_are_counted_separately(client, card_factory):
    """`times_shown` tracks displays; `total_reviews` tracks answers."""
    await card_factory("word", "meaning")

    await client.get("/api/v1/study/next")
    await client.get("/api/v1/study/next")

    body = (await client.get("/api/v1/stats")).json()
    assert body["study"]["total_shows"] == 2
    assert body["study"]["studied_unique"] == 1
    assert body["study"]["total_reviews"] == 0


async def test_never_studied_count(client, card_factory):
    await card_factory("touched", "a")
    await card_factory("untouched", "b")
    await client.get("/api/v1/study/next")

    body = (await client.get("/api/v1/stats")).json()
    assert body["study"]["never_studied"] == 1


# -------------------------------------------------------------- schedule ----
async def test_new_cards_are_due_immediately(client, card_factory):
    await card_factory("fresh", "x")
    body = (await client.get("/api/v1/stats")).json()
    assert body["schedule"]["due_now"] == 1
    assert body["schedule"]["new_count"] == 1
    assert body["schedule"]["learning"] == 1


async def test_answering_easy_moves_a_card_out_of_the_due_pile(client, card_factory):
    card = await card_factory("word", "meaning")
    await client.post(f"/api/v1/study/{card['id']}/answer", json={"rating": "easy"})

    body = (await client.get("/api/v1/stats")).json()
    assert body["schedule"]["due_now"] == 0
    assert body["schedule"]["new_count"] == 0
    assert body["schedule"]["review"] == 1
    assert body["schedule"]["avg_stability_days"] > 0


async def test_suspended_cards_are_not_counted_as_due(client, card_factory):
    card = await card_factory("word", "x")
    await client.patch(f"/api/v1/cards/{card['id']}", json={"suspended": True})

    body = (await client.get("/api/v1/stats")).json()
    assert body["schedule"]["due_now"] == 0


async def test_average_star_rating(client, card_factory):
    await card_factory("a", "a", star_rating=2)
    await card_factory("b", "b", star_rating=4)
    await card_factory("c", "c")  # unrated, must not drag the average down

    body = (await client.get("/api/v1/stats")).json()
    assert body["schedule"]["avg_star_rating"] == pytest.approx(3.0)


# --------------------------------------------------------------- leeches ----
async def test_leeches_surface_repeatedly_forgotten_cards(client, card_factory):
    easy = await card_factory("easy", "a")
    leech = await card_factory("leech", "b")

    await client.post(f"/api/v1/study/{easy['id']}/answer", json={"rating": "easy"})
    for _ in range(3):
        await client.post(f"/api/v1/study/{leech['id']}/answer", json={"rating": "easy"})
        await client.post(f"/api/v1/study/{leech['id']}/answer", json={"rating": "again"})

    body = (await client.get("/api/v1/stats")).json()
    assert [c["term"] for c in body["leeches"]] == ["leech"]
    assert body["leeches"][0]["lapses"] == 3


# -------------------------------------------------------------- activity ----
async def test_activity_and_streak_after_studying_today(client, card_factory):
    card = await card_factory("word", "meaning")
    await client.post(f"/api/v1/study/{card['id']}/answer", json={"rating": "good"})

    body = (await client.get("/api/v1/stats")).json()
    today = datetime.now(UTC).date().isoformat()
    assert body["reviews_last_30_days"] == [{"day": today, "reviews": 1, "correct": 1}]
    assert body["current_streak_days"] == 1


async def test_undone_reviews_drop_out_of_the_counts(client, card_factory):
    card = await card_factory("word", "meaning")
    await client.post(f"/api/v1/study/{card['id']}/answer", json={"rating": "good"})
    await client.post(f"/api/v1/study/{card['id']}/undo")

    body = (await client.get("/api/v1/stats")).json()
    assert body["study"]["total_reviews"] == 0
    assert body["study"]["correct"] == 0


async def test_heatmap_aggregates_reviews_by_day(client, card_factory):
    card = await card_factory("word", "meaning")
    for rating in ("good", "again", "good"):
        await client.post(f"/api/v1/study/{card['id']}/answer", json={"rating": rating})

    body = (await client.get("/api/v1/stats/heatmap?days=30")).json()
    assert body["total_reviews"] == 3
    assert body["max_reviews"] == 3
    assert len(body["days"]) == 1


async def test_backdated_reviews_land_on_the_right_day(client, card_factory):
    card = await card_factory("word", "meaning")
    yesterday = datetime.now(UTC) - timedelta(days=1)

    await client.post(
        f"/api/v1/study/{card['id']}/answer",
        json={"rating": "good", "reviewed_at": yesterday.isoformat()},
    )

    body = (await client.get("/api/v1/stats")).json()
    days = {entry["day"] for entry in body["reviews_last_30_days"]}
    assert yesterday.date().isoformat() in days

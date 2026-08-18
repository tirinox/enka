from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta


async def test_next_card_marks_it_as_shown(client, card_factory):
    card = await card_factory("das Fenster", "window")

    response = await client.get("/api/v1/study/next")
    assert response.status_code == 200
    body = response.json()
    assert body["card"]["id"] == card["id"]
    assert body["card"]["times_shown"] == 1
    assert body["card"]["last_shown_at"] is not None


async def test_peeking_does_not_count_as_shown(client, card_factory):
    await card_factory("term", "def")

    body = (await client.get("/api/v1/study/next?mark_shown=false")).json()
    assert body["card"]["times_shown"] == 0


async def test_empty_collection_reports_nothing_to_study(client):
    response = await client.get("/api/v1/study/next")
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "not_found"


async def test_suspended_cards_are_never_served(client, card_factory):
    await card_factory("hidden", "x", suspended=True)
    assert (await client.get("/api/v1/study/next")).status_code == 404


async def test_deleted_cards_are_never_served(client, card_factory):
    card = await card_factory("temporary", "x")
    await client.delete(f"/api/v1/cards/{card['id']}")
    assert (await client.get("/api/v1/study/next")).status_code == 404


async def test_due_mode_only_returns_due_cards(client):
    future = (datetime.now(UTC) + timedelta(days=5)).isoformat()
    await client.post("/api/v1/cards", json={"term": "later", "due_at": future})

    assert (await client.get("/api/v1/study/next?mode=due")).status_code == 404

    await client.post("/api/v1/cards", json={"term": "now"})
    body = (await client.get("/api/v1/study/next?mode=due")).json()
    assert body["card"]["term"] == "now"


async def test_new_mode_skips_cards_already_answered(client, card_factory):
    answered = await card_factory("answered", "x")
    await client.post(f"/api/v1/study/{answered['id']}/answer", json={"rating": "good"})
    await card_factory("untouched", "y")

    body = (await client.get("/api/v1/study/next?mode=new")).json()
    assert body["card"]["term"] == "untouched"


async def test_smart_mode_falls_through_to_new_when_nothing_is_due(client):
    future = (datetime.now(UTC) + timedelta(days=5)).isoformat()
    await client.post("/api/v1/cards", json={"term": "scheduled", "due_at": future})

    body = (await client.get("/api/v1/study/next?mode=smart")).json()
    assert body["mode"] == "new"
    assert body["card"]["term"] == "scheduled"


async def test_reinforce_mode_puts_the_most_forgotten_card_first(client, card_factory):
    easy = await card_factory("easy one", "a")
    hard = await card_factory("hard one", "b")

    # Build a history where `hard` has been forgotten repeatedly.
    await client.post(f"/api/v1/study/{easy['id']}/answer", json={"rating": "easy"})
    for _ in range(3):
        await client.post(f"/api/v1/study/{hard['id']}/answer", json={"rating": "easy"})
        await client.post(f"/api/v1/study/{hard['id']}/answer", json={"rating": "again"})

    body = (await client.get("/api/v1/study/next?mode=reinforce")).json()
    assert body["card"]["term"] == "hard one"


async def test_random_mode_serves_a_card(client, card_factory):
    await card_factory("only one", "x")
    body = (await client.get("/api/v1/study/next?mode=random")).json()
    assert body["card"]["term"] == "only one"


async def test_tag_filter_scopes_the_session(client):
    await client.post("/api/v1/cards", json={"term": "spanish", "tags": ["es"]})
    await client.post("/api/v1/cards", json={"term": "german", "tags": ["de"]})

    body = (await client.get("/api/v1/study/next?tags=es")).json()
    assert body["card"]["term"] == "spanish"


async def test_direction_is_echoed_back(client, card_factory):
    await card_factory("term", "definition")
    body = (await client.get("/api/v1/study/next?direction=def_to_term")).json()
    assert body["direction"] == "def_to_term"


async def test_cards_without_a_definition_are_always_asked_term_first(client, card_factory):
    """There is nothing on the other side to prompt with yet."""
    await card_factory("lonely term")
    body = (await client.get("/api/v1/study/next?direction=def_to_term")).json()
    assert body["direction"] == "term_to_def"


async def test_queue_returns_a_batch_without_marking(client):
    for i in range(5):
        await client.post("/api/v1/cards", json={"term": f"card-{i}"})

    body = (await client.get("/api/v1/study/queue?limit=3")).json()
    assert len(body["items"]) == 3
    assert all(item["card"]["times_shown"] == 0 for item in body["items"])


# ---------------------------------------------------------------- answers ---
async def test_again_reschedules_within_minutes(client, card_factory):
    card = await card_factory("word", "meaning")

    response = await client.post(f"/api/v1/study/{card['id']}/answer", json={"rating": "again"})
    assert response.status_code == 200
    body = response.json()
    assert body["interval_seconds"] < 600
    assert body["card"]["wrong_count"] == 1
    assert body["card"]["correct_count"] == 0


async def test_easy_reschedules_days_out(client, card_factory):
    card = await card_factory("word", "meaning")

    body = (await client.post(f"/api/v1/study/{card['id']}/answer", json={"rating": "easy"})).json()
    assert body["interval_seconds"] > 86400
    assert "day" in body["interval_human"]
    assert body["card"]["correct_count"] == 1


async def test_answering_advances_the_due_date_monotonically(client, card_factory):
    card = await card_factory("word", "meaning")
    original_due = card["due_at"]

    body = (await client.post(f"/api/v1/study/{card['id']}/answer", json={"rating": "good"})).json()
    assert body["card"]["due_at"] > original_due
    assert body["card"]["last_review_at"] is not None
    assert body["card"]["stability"] is not None


async def test_answer_accepts_direction_and_elapsed_time(client, card_factory):
    card = await card_factory("word", "meaning")
    response = await client.post(
        f"/api/v1/study/{card['id']}/answer",
        json={"rating": "hard", "direction": "def_to_term", "elapsed_ms": 4200},
    )
    assert response.status_code == 200


async def test_answer_rejects_an_unknown_rating(client, card_factory):
    card = await card_factory("word", "meaning")
    response = await client.post(f"/api/v1/study/{card['id']}/answer", json={"rating": "sort-of"})
    assert response.status_code == 422


async def test_answering_an_unknown_card_is_404(client):
    response = await client.post(f"/api/v1/study/{uuid.uuid4()}/answer", json={"rating": "good"})
    assert response.status_code == 404


async def test_backdated_answer_is_accepted(client, card_factory):
    """Lets an offline client replay a session recorded earlier."""
    card = await card_factory("word", "meaning")
    yesterday = (datetime.now(UTC) - timedelta(days=1)).isoformat()

    response = await client.post(
        f"/api/v1/study/{card['id']}/answer",
        json={"rating": "good", "reviewed_at": yesterday},
    )
    assert response.status_code == 200
    assert response.json()["card"]["last_review_at"].startswith(yesterday[:10])


# ------------------------------------------------------------------- undo ---
async def test_undo_restores_the_card(client, card_factory):
    card = await card_factory("word", "meaning")
    before = (await client.get(f"/api/v1/cards/{card['id']}")).json()

    await client.post(f"/api/v1/study/{card['id']}/answer", json={"rating": "again"})
    undone = (await client.post(f"/api/v1/study/{card['id']}/undo")).json()

    assert undone["card"]["due_at"] == before["due_at"]
    assert undone["card"]["wrong_count"] == 0
    assert undone["card"]["stability"] is None


async def test_undo_without_a_review_is_a_conflict(client, card_factory):
    card = await card_factory("word", "meaning")
    response = await client.post(f"/api/v1/study/{card['id']}/undo")
    assert response.status_code == 409


async def test_undo_only_reverts_the_most_recent_answer(client, card_factory):
    card = await card_factory("word", "meaning")
    await client.post(f"/api/v1/study/{card['id']}/answer", json={"rating": "good"})
    after_first = (await client.get(f"/api/v1/cards/{card['id']}")).json()

    await client.post(f"/api/v1/study/{card['id']}/answer", json={"rating": "again"})
    undone = (await client.post(f"/api/v1/study/{card['id']}/undo")).json()

    assert undone["card"]["due_at"] == after_first["due_at"]
    assert undone["card"]["correct_count"] == 1


async def test_remaining_due_counts_down_as_you_answer(client):
    for i in range(3):
        await client.post("/api/v1/cards", json={"term": f"card-{i}"})

    first = (await client.get("/api/v1/study/next")).json()
    assert first["remaining_due"] == 3

    body = (
        await client.post(f"/api/v1/study/{first['card']['id']}/answer", json={"rating": "easy"})
    ).json()
    assert body["remaining_due"] == 2

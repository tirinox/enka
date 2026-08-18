"""Fuzzy search — the feature that answers "do I already have this word?"."""

from __future__ import annotations

import pytest


@pytest.fixture
async def collection(client):
    for term, definition in [
        ("das Fenster", "window"),
        ("café", "coffee"),
        ("Übung", "exercise"),
        ("привет", "hello"),
        ("сегодня", "today"),
        ("el aeropuerto", "airport"),
    ]:
        await client.post("/api/v1/cards", json={"term": term, "definition": definition})
    return client


async def test_typo_still_finds_the_card(collection):
    body = (await collection.get("/api/v1/cards/search?q=fenstr")).json()
    assert [h["card"]["term"] for h in body["hits"]] == ["das Fenster"]
    assert body["exact_match"] is False


async def test_accents_are_ignored(collection):
    body = (await collection.get("/api/v1/cards/search?q=cafe")).json()
    assert body["exact_match"] is True
    assert body["hits"][0]["card"]["term"] == "café"


async def test_umlauts_are_ignored(collection):
    body = (await collection.get("/api/v1/cards/search?q=ubung")).json()
    assert body["exact_match"] is True
    assert body["hits"][0]["card"]["term"] == "Übung"


async def test_cyrillic_is_case_folded(collection):
    """Regression: an Alpine/musl Postgres would fail this, because lower()
    there is a no-op outside ASCII."""
    body = (await collection.get("/api/v1/cards/search?q=ПРИВЕТ")).json()
    assert body["exact_match"] is True
    assert body["hits"][0]["card"]["term"] == "привет"


async def test_exact_match_flag_is_true_for_identical_term(collection):
    body = (await collection.get("/api/v1/cards/search?q=das%20Fenster")).json()
    assert body["exact_match"] is True
    assert body["hits"][0]["score"] == 1.0


async def test_exact_match_outranks_a_fuzzier_row(client):
    await client.post("/api/v1/cards", json={"term": "sein"})
    await client.post("/api/v1/cards", json={"term": "seine"})
    await client.post("/api/v1/cards", json={"term": "seinen"})

    body = (await client.get("/api/v1/cards/search?q=sein")).json()
    assert body["hits"][0]["card"]["term"] == "sein"
    assert body["exact_match"] is True


async def test_search_works_definition_to_term(collection):
    body = (await collection.get("/api/v1/cards/search?q=windo")).json()
    assert body["hits"][0]["card"]["term"] == "das Fenster"
    assert body["hits"][0]["matched_side"] == "definition"


async def test_side_filter_restricts_matching(collection):
    """`window` is only on the definition side, so a term-only search misses it."""
    both = (await collection.get("/api/v1/cards/search?q=window&side=both")).json()
    assert both["hits"]

    term_only = (await collection.get("/api/v1/cards/search?q=window&side=term")).json()
    assert term_only["hits"] == []


async def test_deleted_cards_are_not_searchable(client):
    card = (
        await client.post("/api/v1/cards", json={"term": "ephemeral", "definition": "brief"})
    ).json()
    await client.delete(f"/api/v1/cards/{card['id']}")

    body = (await client.get("/api/v1/cards/search?q=ephemeral")).json()
    assert body["hits"] == []
    assert body["exact_match"] is False


async def test_no_match_returns_empty_not_error(collection):
    body = (await collection.get("/api/v1/cards/search?q=zzzzqqqxyw")).json()
    assert body["hits"] == []
    assert body["exact_match"] is False


async def test_blank_query_is_rejected(collection):
    assert (await collection.get("/api/v1/cards/search?q=")).status_code == 422


async def test_threshold_controls_fuzziness(collection):
    loose = (await collection.get("/api/v1/cards/search?q=fenst&threshold=0.1")).json()
    strict = (await collection.get("/api/v1/cards/search?q=fenst&threshold=0.9")).json()
    assert len(loose["hits"]) >= len(strict["hits"])


async def test_limit_is_respected(client):
    for i in range(10):
        await client.post("/api/v1/cards", json={"term": f"testword{i}"})

    body = (await client.get("/api/v1/cards/search?q=testword&limit=3")).json()
    assert len(body["hits"]) == 3

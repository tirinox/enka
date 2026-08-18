from __future__ import annotations

import uuid


async def test_create_minimal_card(client):
    response = await client.post("/api/v1/cards", json={"term": "das Fenster"})
    assert response.status_code == 201
    card = response.json()
    assert card["term"] == "das Fenster"
    assert card["definition"] is None
    assert card["times_shown"] == 0
    assert card["srs_state"] == 1
    assert card["retrievability"] is None


async def test_definition_may_be_added_later(client, card_factory):
    """The whole point of a nullable definition: capture the word now."""
    card = await card_factory("la sobremesa")
    assert card["definition"] is None

    updated = await client.patch(
        f"/api/v1/cards/{card['id']}",
        json={"definition": "after-meal conversation"},
    )
    assert updated.status_code == 200
    assert updated.json()["definition"] == "after-meal conversation"


async def test_blank_term_is_rejected(client):
    response = await client.post("/api/v1/cards", json={"term": "   "})
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"


async def test_whitespace_only_definition_becomes_null(client):
    response = await client.post("/api/v1/cards", json={"term": "word", "definition": "   "})
    assert response.json()["definition"] is None


async def test_term_is_trimmed(client):
    response = await client.post("/api/v1/cards", json={"term": "  spaced  "})
    assert response.json()["term"] == "spaced"


async def test_star_rating_bounds_enforced(client):
    assert (
        await client.post("/api/v1/cards", json={"term": "x", "star_rating": 6})
    ).status_code == 422
    assert (
        await client.post("/api/v1/cards", json={"term": "y", "star_rating": 0})
    ).status_code == 422
    assert (
        await client.post("/api/v1/cards", json={"term": "z", "star_rating": 5})
    ).status_code == 201


async def test_get_unknown_card_is_404(client):
    response = await client.get(f"/api/v1/cards/{uuid.uuid4()}")
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "not_found"


async def test_patch_only_touches_supplied_fields(client, card_factory):
    card = await card_factory("term", "definition", notes="keep me")

    response = await client.patch(f"/api/v1/cards/{card['id']}", json={"star_rating": 4})
    body = response.json()
    assert body["star_rating"] == 4
    assert body["definition"] == "definition"
    assert body["notes"] == "keep me"


async def test_tags_are_created_on_demand_and_replaced_wholesale(client, card_factory):
    card = await card_factory("das Auto", "car", tags=["de", "nouns"])
    assert sorted(card["tags"]) == ["de", "nouns"]

    updated = await client.patch(f"/api/v1/cards/{card['id']}", json={"tags": ["vehicles"]})
    assert updated.json()["tags"] == ["vehicles"]

    tags = (await client.get("/api/v1/tags")).json()
    by_name = {t["name"]: t["card_count"] for t in tags}
    assert by_name["vehicles"] == 1
    assert by_name["de"] == 0  # tag survives, association gone


async def test_tags_are_case_insensitive(client):
    await client.post("/api/v1/cards", json={"term": "a", "tags": ["Verbs"]})
    await client.post("/api/v1/cards", json={"term": "b", "tags": ["verbs"]})

    tags = (await client.get("/api/v1/tags")).json()
    assert len([t for t in tags if t["name"].lower() == "verbs"]) == 1
    assert tags[0]["card_count"] == 2


async def test_soft_delete_hides_card_but_keeps_tombstone(client, card_factory):
    card = await card_factory("temporary")

    assert (await client.delete(f"/api/v1/cards/{card['id']}")).status_code == 204
    assert (await client.get(f"/api/v1/cards/{card['id']}")).status_code == 404

    listed = (await client.get("/api/v1/cards")).json()
    assert card["id"] not in [c["id"] for c in listed["items"]]

    with_deleted = (await client.get("/api/v1/cards?include_deleted=true")).json()
    tombstone = next(c for c in with_deleted["items"] if c["id"] == card["id"])
    assert tombstone["deleted_at"] is not None


async def test_restore_undoes_a_soft_delete(client, card_factory):
    card = await card_factory("oops")
    await client.delete(f"/api/v1/cards/{card['id']}")

    restored = await client.post(f"/api/v1/cards/{card['id']}/restore")
    assert restored.status_code == 200
    assert restored.json()["deleted_at"] is None
    assert (await client.get(f"/api/v1/cards/{card['id']}")).status_code == 200


async def test_restoring_a_live_card_is_a_conflict(client, card_factory):
    card = await card_factory("alive")
    response = await client.post(f"/api/v1/cards/{card['id']}/restore")
    assert response.status_code == 409


async def test_hard_delete_leaves_nothing_behind(client, card_factory):
    card = await card_factory("gone for good")

    assert (await client.delete(f"/api/v1/cards/{card['id']}?hard=true")).status_code == 204

    with_deleted = (await client.get("/api/v1/cards?include_deleted=true")).json()
    assert card["id"] not in [c["id"] for c in with_deleted["items"]]


async def test_bulk_create_skips_duplicates(client, card_factory):
    await card_factory("existing")

    response = await client.post(
        "/api/v1/cards/bulk",
        json={
            "cards": [
                {"term": "existing"},
                {"term": "EXISTING"},  # same term, different case
                {"term": "brand new"},
                {"term": "brand new"},  # duplicate within the batch
            ]
        },
    )
    assert response.status_code == 201
    body = response.json()
    assert [c["term"] for c in body["created"]] == ["brand new"]
    assert len(body["skipped_duplicates"]) == 3


async def test_bulk_create_can_allow_duplicates(client, card_factory):
    await card_factory("dup")
    response = await client.post(
        "/api/v1/cards/bulk?skip_duplicates=false",
        json={"cards": [{"term": "dup"}]},
    )
    assert len(response.json()["created"]) == 1


async def test_pagination_reports_total_and_has_more(client):
    for i in range(5):
        await client.post("/api/v1/cards", json={"term": f"card-{i}"})

    page = (await client.get("/api/v1/cards?limit=2&offset=0")).json()
    assert page["total"] == 5
    assert len(page["items"]) == 2
    assert page["has_more"] is True

    last = (await client.get("/api/v1/cards?limit=2&offset=4")).json()
    assert last["has_more"] is False


async def test_filters(client):
    await client.post("/api/v1/cards", json={"term": "with def", "definition": "yes"})
    await client.post("/api/v1/cards", json={"term": "without def"})
    await client.post("/api/v1/cards", json={"term": "tagged", "tags": ["x"]})
    await client.post("/api/v1/cards", json={"term": "suspended one", "suspended": True})

    no_def = (await client.get("/api/v1/cards?has_definition=false")).json()
    assert {c["term"] for c in no_def["items"]} == {"without def", "tagged", "suspended one"}

    tagged = (await client.get("/api/v1/cards?tags=x")).json()
    assert [c["term"] for c in tagged["items"]] == ["tagged"]

    suspended = (await client.get("/api/v1/cards?suspended=true")).json()
    assert [c["term"] for c in suspended["items"]] == ["suspended one"]


async def test_tag_mode_all_requires_every_tag(client):
    await client.post("/api/v1/cards", json={"term": "both", "tags": ["a", "b"]})
    await client.post("/api/v1/cards", json={"term": "only-a", "tags": ["a"]})

    any_hits = (await client.get("/api/v1/cards?tags=a&tags=b&tag_mode=any")).json()
    assert any_hits["total"] == 2

    all_hits = (await client.get("/api/v1/cards?tags=a&tags=b&tag_mode=all")).json()
    assert [c["term"] for c in all_hits["items"]] == ["both"]


async def test_sorting_by_term(client):
    for term in ("cherry", "apple", "banana"):
        await client.post("/api/v1/cards", json={"term": term})

    page = (await client.get("/api/v1/cards?sort=term&order=asc")).json()
    assert [c["term"] for c in page["items"]] == ["apple", "banana", "cherry"]


async def test_substring_filter_searches_all_text_fields(client):
    await client.post(
        "/api/v1/cards", json={"term": "abc", "definition": "xyz", "notes": "hidden gem"}
    )
    await client.post("/api/v1/cards", json={"term": "other"})

    assert (await client.get("/api/v1/cards?q=gem")).json()["total"] == 1
    assert (await client.get("/api/v1/cards?q=xyz")).json()["total"] == 1

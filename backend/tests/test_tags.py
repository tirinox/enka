from __future__ import annotations

import uuid


async def test_create_and_list_tags(client):
    response = await client.post("/api/v1/tags", json={"name": "verbs", "color": "#c56b3a"})
    assert response.status_code == 201
    assert response.json()["name"] == "verbs"

    tags = (await client.get("/api/v1/tags")).json()
    assert [t["name"] for t in tags] == ["verbs"]
    assert tags[0]["card_count"] == 0


async def test_duplicate_tag_names_are_rejected_case_insensitively(client):
    await client.post("/api/v1/tags", json={"name": "verbs"})
    clash = await client.post("/api/v1/tags", json={"name": "VERBS"})
    assert clash.status_code == 409
    assert clash.json()["error"]["code"] == "conflict"


async def test_tag_names_are_whitespace_normalised(client):
    response = await client.post("/api/v1/tags", json={"name": "  phrasal   verbs  "})
    assert response.json()["name"] == "phrasal verbs"


async def test_card_counts_ignore_deleted_cards(client, card_factory):
    card = await card_factory("word", "meaning", tags=["nouns"])

    assert (await client.get("/api/v1/tags")).json()[0]["card_count"] == 1

    await client.delete(f"/api/v1/cards/{card['id']}")
    assert (await client.get("/api/v1/tags")).json()[0]["card_count"] == 0


async def test_rename_a_tag(client, card_factory):
    await card_factory("word", "meaning", tags=["nouns"])
    tag_id = (await client.get("/api/v1/tags")).json()[0]["id"]

    response = await client.patch(f"/api/v1/tags/{tag_id}", json={"name": "substantives"})
    assert response.status_code == 200

    card_list = (await client.get("/api/v1/cards")).json()
    assert card_list["items"][0]["tags"] == ["substantives"]


async def test_renaming_onto_an_existing_name_conflicts(client):
    await client.post("/api/v1/tags", json={"name": "a"})
    second = (await client.post("/api/v1/tags", json={"name": "b"})).json()

    response = await client.patch(f"/api/v1/tags/{second['id']}", json={"name": "a"})
    assert response.status_code == 409


async def test_renaming_a_tag_to_its_own_name_is_fine(client):
    tag = (await client.post("/api/v1/tags", json={"name": "keep"})).json()
    response = await client.patch(f"/api/v1/tags/{tag['id']}", json={"name": "keep"})
    assert response.status_code == 200


async def test_deleting_a_tag_leaves_the_cards_alone(client, card_factory):
    card = await card_factory("word", "meaning", tags=["temporary"])
    tag_id = (await client.get("/api/v1/tags")).json()[0]["id"]

    assert (await client.delete(f"/api/v1/tags/{tag_id}")).status_code == 204

    fetched = (await client.get(f"/api/v1/cards/{card['id']}")).json()
    assert fetched["tags"] == []
    assert fetched["term"] == "word"


async def test_unknown_tag_is_404(client):
    missing = uuid.uuid4()
    assert (await client.patch(f"/api/v1/tags/{missing}", json={"name": "x"})).status_code == 404
    assert (await client.delete(f"/api/v1/tags/{missing}")).status_code == 404


async def test_tags_are_listed_alphabetically(client):
    for name in ("zebra", "apple", "Mango"):
        await client.post("/api/v1/tags", json={"name": name})

    tags = (await client.get("/api/v1/tags")).json()
    assert [t["name"] for t in tags] == ["apple", "Mango", "zebra"]

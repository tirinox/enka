"""Delta sync — what the macOS and web clients will build on.

The contract: a client stores `server_time` from its last response and passes
it back as `updated_since`, with `include_deleted=true` so deletions propagate.
"""

from __future__ import annotations

import asyncio


async def test_list_response_carries_a_server_timestamp(client):
    body = (await client.get("/api/v1/cards")).json()
    assert body["server_time"]


async def test_updated_since_returns_only_what_changed(client, card_factory):
    await card_factory("first")
    watermark = (await client.get("/api/v1/cards")).json()["server_time"]

    await asyncio.sleep(0.01)
    await card_factory("second")

    delta = (await client.get(f"/api/v1/cards?updated_since={watermark}")).json()
    assert [c["term"] for c in delta["items"]] == ["second"]


async def test_editing_a_card_makes_it_reappear_in_the_delta(client, card_factory):
    card = await card_factory("original")
    watermark = (await client.get("/api/v1/cards")).json()["server_time"]

    await asyncio.sleep(0.01)
    await client.patch(f"/api/v1/cards/{card['id']}", json={"definition": "added later"})

    delta = (await client.get(f"/api/v1/cards?updated_since={watermark}")).json()
    assert [c["id"] for c in delta["items"]] == [card["id"]]


async def test_deletion_propagates_as_a_tombstone(client, card_factory):
    card = await card_factory("doomed")
    watermark = (await client.get("/api/v1/cards")).json()["server_time"]

    await asyncio.sleep(0.01)
    await client.delete(f"/api/v1/cards/{card['id']}")

    delta = (
        await client.get(f"/api/v1/cards?updated_since={watermark}&include_deleted=true")
    ).json()
    assert len(delta["items"]) == 1
    assert delta["items"][0]["deleted_at"] is not None


async def test_without_include_deleted_a_client_would_miss_the_deletion(client, card_factory):
    """Documents why include_deleted matters: the row simply vanishes."""
    card = await card_factory("doomed")
    watermark = (await client.get("/api/v1/cards")).json()["server_time"]

    await asyncio.sleep(0.01)
    await client.delete(f"/api/v1/cards/{card['id']}")

    delta = (await client.get(f"/api/v1/cards?updated_since={watermark}")).json()
    assert delta["items"] == []


async def test_a_quiet_period_yields_an_empty_delta(client, card_factory):
    await card_factory("settled")
    watermark = (await client.get("/api/v1/cards")).json()["server_time"]

    delta = (await client.get(f"/api/v1/cards?updated_since={watermark}")).json()
    assert delta["items"] == []
    assert delta["total"] == 0


async def test_studying_a_card_shows_up_in_the_delta(client, card_factory):
    """Scheduling changes must sync too, or devices disagree about what's due."""
    card = await card_factory("word", "meaning")
    watermark = (await client.get("/api/v1/cards")).json()["server_time"]

    await asyncio.sleep(0.01)
    await client.post(f"/api/v1/study/{card['id']}/answer", json={"rating": "good"})

    delta = (await client.get(f"/api/v1/cards?updated_since={watermark}")).json()
    assert [c["id"] for c in delta["items"]] == [card["id"]]


async def test_hard_deleted_cards_leave_no_tombstone(client, card_factory):
    """Purging is genuinely irreversible — worth asserting so it never
    silently becomes a soft delete."""
    card = await card_factory("purged")
    watermark = (await client.get("/api/v1/cards")).json()["server_time"]

    await asyncio.sleep(0.01)
    await client.delete(f"/api/v1/cards/{card['id']}?hard=true")

    delta = (
        await client.get(f"/api/v1/cards?updated_since={watermark}&include_deleted=true")
    ).json()
    assert delta["items"] == []

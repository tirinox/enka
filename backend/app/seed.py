"""Load a few demo cards so a fresh install has something to look at.

    make seed

Idempotent: terms that already exist are skipped.
"""

from __future__ import annotations

import asyncio

from sqlalchemy import func, select

from app.db.session import SessionLocal, engine
from app.models.card import Card
from app.models.owner import Owner
from app.services.cards import resolve_tags

DEMO: list[tuple[str, str | None, list[str]]] = [
    ("das Fenster", "window", ["de", "nouns"]),
    ("die Katze", "cat", ["de", "nouns"]),
    ("sich freuen", "to be glad, to look forward to", ["de", "verbs"]),
    ("obwohl", "although", ["de", "conjunctions"]),
    ("der Bahnhof", "railway station", ["de", "nouns", "travel"]),
    ("el aeropuerto", "airport", ["es", "nouns", "travel"]),
    ("madrugar", "to get up early", ["es", "verbs"]),
    ("la sobremesa", None, ["es", "nouns"]),  # definition deliberately blank
]


async def seed() -> None:
    async with SessionLocal() as session:
        owner = (await session.execute(select(Owner).limit(1))).scalar_one_or_none()
        if owner is None:
            print("No owner yet — start the API once so it can seed one.")
            return

        existing = set(
            (
                await session.execute(
                    select(func.lower(Card.term)).where(Card.owner_id == owner.id)
                )
            ).scalars()
        )

        added = 0
        for term, definition, tags in DEMO:
            if term.lower() in existing:
                continue
            card = Card(owner_id=owner.id, term=term, definition=definition, srs_step=0)
            card.tags = await resolve_tags(session, owner.id, tags)
            session.add(card)
            added += 1

        await session.commit()
        print(f"Seeded {added} card(s); {len(DEMO) - added} already present.")

    await engine.dispose()


if __name__ == "__main__":
    asyncio.run(seed())

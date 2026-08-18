"""Fuzzy card search built on pg_trgm.

The driving use case is typing a phrase you are about to add and finding out
instantly whether it is already in the collection — so near-misses and typos
must surface, and a genuine exact match must always rank first.
"""

from __future__ import annotations

import unicodedata
import uuid
from typing import Literal

from sqlalchemy import Float, String, case, func, literal, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.card import Card
from app.schemas.card import SearchHit, SearchResponse
from app.services.cards import card_to_out

Side = Literal["term", "definition", "both"]


def _folded(column):
    """lower() then strip accents — so `cafe` matches `Café`.

    Mirrors the expression in the GIN indexes exactly; if these ever diverge,
    the index silently stops being used.
    """
    # type_=String matters: without it SQLAlchemy treats the result as untyped
    # and `.contains()` / `==` build the wrong SQL.
    return func.f_unaccent(func.lower(func.coalesce(column, "")), type_=String)


def _folded_literal(value: str):
    return func.f_unaccent(func.lower(literal(value, type_=String)), type_=String)


async def search_cards(
    session: AsyncSession,
    owner_id: uuid.UUID,
    query: str,
    *,
    side: Side = "both",
    limit: int = 20,
    threshold: float = 0.2,
) -> SearchResponse:
    cleaned = query.strip()
    if not cleaned:
        return SearchResponse(query=query, exact_match=False, hits=[])

    needle = _folded_literal(cleaned)
    term_sim = func.similarity(_folded(Card.term), needle).cast(Float)
    def_sim = func.similarity(_folded(Card.definition), needle).cast(Float)

    if side == "term":
        score = term_sim
        matches = [term_sim > threshold, _folded(Card.term).contains(needle)]
    elif side == "definition":
        score = def_sim
        matches = [def_sim > threshold, _folded(Card.definition).contains(needle)]
    else:
        score = func.greatest(term_sim, def_sim)
        matches = [
            term_sim > threshold,
            def_sim > threshold,
            _folded(Card.term).contains(needle),
            _folded(Card.definition).contains(needle),
        ]

    # An exact hit scores a flat 1.0 regardless of what trigram similarity says
    # about it — "already have this word" is the answer the caller came for.
    exact = case(
        (_folded(Card.term) == needle, literal(1.0)),
        (_folded(Card.definition) == needle, literal(1.0)),
        else_=literal(0.0),
    ).cast(Float)
    ranked = func.greatest(score, exact)

    stmt = (
        select(
            Card,
            ranked.label("score"),
            term_sim.label("term_score"),
            def_sim.label("def_score"),
        )
        .where(Card.owner_id == owner_id, Card.deleted_at.is_(None))
        .where(or_(*matches))
        .order_by(ranked.desc(), Card.term.asc())
        .limit(limit)
    )

    rows = (await session.execute(stmt)).all()

    hits: list[SearchHit] = []
    exact_match = False
    folded_query = _fold_python(cleaned)
    for card, card_score, term_score, def_score in rows:
        if _fold_python(card.term) == folded_query or (
            card.definition and _fold_python(card.definition) == folded_query
        ):
            exact_match = True
        hits.append(
            SearchHit(
                card=card_to_out(card),
                score=round(float(card_score), 4),
                matched_side="term" if (term_score or 0) >= (def_score or 0) else "definition",
            )
        )

    return SearchResponse(query=cleaned, exact_match=exact_match, hits=hits)


def _fold_python(value: str) -> str:
    """Approximate f_unaccent(lower(...)) in Python.

    Used only to set the ``exact_match`` flag on rows Postgres already returned,
    so a small divergence from the SQL folding cannot affect *which* rows match.
    """
    decomposed = unicodedata.normalize("NFKD", value.strip().lower())
    return "".join(ch for ch in decomposed if not unicodedata.combining(ch))

"""Regression guard for the trigram indexes.

Postgres only uses an expression index when the query spells the expression
identically. That coupling is invisible — search keeps returning correct
results while quietly falling back to a full table scan — so it needs a test.

The expressions here come from ``services.search`` itself rather than being
retyped, so the test fails if the query helper and the migration drift apart.
"""

from __future__ import annotations

import pytest
from sqlalchemy import select, text
from sqlalchemy.dialects import postgresql

from app.models.card import Card
from app.services.search import _folded, _folded_literal


def _explain_sql(expression) -> str:
    stmt = select(Card.id).where(expression)
    # asyncpg's dialect uses numeric ($1) parameters, so it does not double up
    # the `%` of the trigram similarity operator the way the pyformat dialect
    # would. Compiling with the default dialect here would emit `%%` and
    # Postgres would reject it as an unknown operator.
    compiled = stmt.compile(
        dialect=postgresql.asyncpg.dialect(), compile_kwargs={"literal_binds": True}
    )
    return f"EXPLAIN {compiled}"


async def _plan_for(db, expression) -> str:
    # enable_seqscan=off asks: *can* the planner use the index at all? That is
    # a property of expression matching, not of table size — so the assertion
    # stays meaningful on an almost-empty test database.
    await db.execute(text("SET LOCAL enable_seqscan = off"))
    rows = (await db.execute(text(_explain_sql(expression)))).scalars().all()
    return "\n".join(rows)


@pytest.mark.parametrize(
    ("column", "index_name"),
    [(Card.term, "ix_card_term_trgm"), (Card.definition, "ix_card_definition_trgm")],
)
async def test_similarity_search_can_use_the_trigram_index(db, column, index_name):
    plan = await _plan_for(db, _folded(column).op("%")(_folded_literal("fenster")))
    assert index_name in plan, f"trigram index unused; plan was:\n{plan}"


@pytest.mark.parametrize(
    ("column", "index_name"),
    [(Card.term, "ix_card_term_trgm"), (Card.definition, "ix_card_definition_trgm")],
)
async def test_substring_search_can_use_the_trigram_index(db, column, index_name):
    plan = await _plan_for(db, _folded(column).contains(_folded_literal("fenst")))
    assert index_name in plan, f"trigram index unused; plan was:\n{plan}"


async def test_f_unaccent_is_immutable(db):
    """If it were only STABLE the indexes above could not exist at all."""
    volatility = (
        await db.execute(
            text(
                "SELECT provolatile::text FROM pg_proc WHERE proname = 'f_unaccent' "
                "AND pronargs = 1"
            )
        )
    ).scalar_one()
    assert volatility == "i", "f_unaccent must be IMMUTABLE or it cannot be indexed"


async def test_f_unaccent_folds_the_alphabets_we_care_about(db):
    row = (
        await db.execute(
            text(
                "SELECT f_unaccent(lower('CAFÉ')), f_unaccent(lower('ÜBUNG')), "
                "f_unaccent(lower('ПРИВЕТ'))"
            )
        )
    ).one()
    assert tuple(row) == ("cafe", "ubung", "привет")

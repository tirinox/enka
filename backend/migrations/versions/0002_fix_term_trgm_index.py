"""match the term trigram index to the search expression

Postgres only uses an expression index when the query's expression is written
identically. ``services/search.py`` folds both sides with one helper, which
applies ``coalesce(col, '')`` because ``definition`` is nullable — so the term
index created in 0001 (without the coalesce) was never chosen and term search
silently degraded to a sequential scan.

``term`` is NOT NULL, so the coalesce changes no results; it only makes the two
expressions match.

Revision ID: 0002
Revises: 0001
Create Date: 2026-08-18
"""

from __future__ import annotations

from collections.abc import Sequence

from alembic import op

revision: str = "0002"
down_revision: str | None = "0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.execute("DROP INDEX IF EXISTS ix_card_term_trgm")
    op.execute(
        "CREATE INDEX ix_card_term_trgm ON card "
        "USING gin (f_unaccent(lower(coalesce(term, ''))) gin_trgm_ops)"
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS ix_card_term_trgm")
    op.execute(
        "CREATE INDEX ix_card_term_trgm ON card "
        "USING gin (f_unaccent(lower(term)) gin_trgm_ops)"
    )

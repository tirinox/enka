"""add owner.native_language

Nullable — unset until the owner picks one. The client prompts for it the
first time a translation is requested (POST /cards/{id}/definition/generate
with mode=native_language) rather than assuming a default.

Revision ID: 905abfb8a7f6
Revises: 0002
Create Date: 2026-08-21
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "905abfb8a7f6"
down_revision: str | None = "0002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("owner", sa.Column("native_language", sa.String(length=8), nullable=True))


def downgrade() -> None:
    op.drop_column("owner", "native_language")

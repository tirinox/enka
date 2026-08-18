"""initial schema

Revision ID: 0001
Revises:
Create Date: 2026-08-18
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # --- extensions -------------------------------------------------------
    op.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")
    op.execute("CREATE EXTENSION IF NOT EXISTS unaccent")

    # unaccent() is STABLE, not IMMUTABLE, because it resolves the dictionary
    # by search_path at call time — which makes it unusable in an index. Naming
    # the dictionary explicitly removes that lookup, so this wrapper is
    # genuinely immutable and can be indexed.
    op.execute(
        """
        CREATE OR REPLACE FUNCTION f_unaccent(text)
        RETURNS text
        LANGUAGE sql
        IMMUTABLE PARALLEL SAFE STRICT
        AS $func$
            SELECT public.unaccent('public.unaccent', $1)
        $func$
        """
    )

    # --- owner ------------------------------------------------------------
    op.create_table(
        "owner",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("name", sa.String(length=120), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("id", name="pk_owner"),
    )

    # --- card -------------------------------------------------------------
    op.create_table(
        "card",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("owner_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("term", sa.Text(), nullable=False),
        sa.Column("definition", sa.Text(), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("suspended", sa.Boolean(), server_default="false", nullable=False),
        sa.Column("last_shown_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("first_studied_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("times_shown", sa.Integer(), server_default="0", nullable=False),
        sa.Column("correct_count", sa.Integer(), server_default="0", nullable=False),
        sa.Column("wrong_count", sa.Integer(), server_default="0", nullable=False),
        sa.Column("lapses", sa.Integer(), server_default="0", nullable=False),
        sa.Column("star_rating", sa.SmallInteger(), nullable=True),
        sa.Column("srs_state", sa.SmallInteger(), server_default="1", nullable=False),
        sa.Column("srs_step", sa.Integer(), nullable=True),
        sa.Column("stability", sa.Float(), nullable=True),
        sa.Column("difficulty", sa.Float(), nullable=True),
        sa.Column("due_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("last_review_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["owner_id"], ["owner.id"], name="fk_card_owner_id_owner", ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id", name="pk_card"),
        sa.CheckConstraint(
            "star_rating IS NULL OR (star_rating BETWEEN 1 AND 5)", name="ck_card_star_rating_range"
        ),
        sa.CheckConstraint("srs_state BETWEEN 1 AND 3", name="ck_card_srs_state_range"),
    )
    op.create_index(
        "ix_card_owner_due",
        "card",
        ["owner_id", "due_at"],
        postgresql_where=sa.text("deleted_at IS NULL AND suspended IS false"),
    )
    op.create_index("ix_card_owner_updated_at", "card", ["owner_id", "updated_at"])
    op.create_index("ix_card_owner_created_at", "card", ["owner_id", "created_at"])

    # --- fuzzy search indexes ---------------------------------------------
    # Trigram GIN over accent- and case-folded text, so `cafe` finds `Café`
    # and `fenstr` finds `das Fenster`.
    op.execute(
        "CREATE INDEX ix_card_term_trgm ON card "
        "USING gin (f_unaccent(lower(term)) gin_trgm_ops)"
    )
    op.execute(
        "CREATE INDEX ix_card_definition_trgm ON card "
        "USING gin (f_unaccent(lower(coalesce(definition, ''))) gin_trgm_ops)"
    )

    # --- tag --------------------------------------------------------------
    op.create_table(
        "tag",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("owner_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("name", sa.String(length=64), nullable=False),
        sa.Column("name_normalized", sa.String(length=64), nullable=False),
        sa.Column("color", sa.String(length=16), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(
            ["owner_id"], ["owner.id"], name="fk_tag_owner_id_owner", ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id", name="pk_tag"),
        sa.UniqueConstraint("owner_id", "name_normalized", name="uq_tag_owner_id_name_normalized"),
    )
    op.create_index("ix_tag_owner_id", "tag", ["owner_id"])

    op.create_table(
        "card_tag",
        sa.Column("card_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tag_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["card_id"], ["card.id"], name="fk_card_tag_card_id_card", ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["tag_id"], ["tag.id"], name="fk_card_tag_tag_id_tag", ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("card_id", "tag_id", name="pk_card_tag"),
    )
    op.create_index("ix_card_tag_tag_id", "card_tag", ["tag_id"])

    # --- audio_clip -------------------------------------------------------
    audio_side = postgresql.ENUM("term", "definition", name="audio_side", create_type=False)
    audio_side.create(op.get_bind(), checkfirst=True)

    op.create_table(
        "audio_clip",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("owner_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("card_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("side", audio_side, nullable=False),
        sa.Column("storage_key", sa.String(length=512), nullable=False),
        sa.Column("original_filename", sa.String(length=255), nullable=True),
        sa.Column("content_type", sa.String(length=100), nullable=False),
        sa.Column("size_bytes", sa.BigInteger(), nullable=False),
        sa.Column("sha256", sa.String(length=64), nullable=False),
        sa.Column("duration_ms", sa.Integer(), nullable=True),
        sa.Column("sort_order", sa.Integer(), server_default="0", nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(
            ["card_id"], ["card.id"], name="fk_audio_clip_card_id_card", ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["owner_id"], ["owner.id"], name="fk_audio_clip_owner_id_owner", ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id", name="pk_audio_clip"),
    )
    op.create_index("ix_audio_clip_card_id_side", "audio_clip", ["card_id", "side"])
    op.create_index("ix_audio_clip_owner_id", "audio_clip", ["owner_id"])

    # --- review_log -------------------------------------------------------
    review_direction = postgresql.ENUM(
        "term_to_def", "def_to_term", name="review_direction", create_type=False
    )
    review_direction.create(op.get_bind(), checkfirst=True)

    op.create_table(
        "review_log",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("owner_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("card_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("reviewed_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("rating", sa.SmallInteger(), nullable=False),
        sa.Column("direction", review_direction, nullable=True),
        sa.Column("elapsed_ms", sa.Integer(), nullable=True),
        sa.Column("prev_state", sa.SmallInteger(), nullable=True),
        sa.Column("prev_step", sa.Integer(), nullable=True),
        sa.Column("prev_stability", sa.Float(), nullable=True),
        sa.Column("prev_difficulty", sa.Float(), nullable=True),
        sa.Column("prev_due_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("prev_last_review_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("new_state", sa.SmallInteger(), nullable=True),
        sa.Column("new_stability", sa.Float(), nullable=True),
        sa.Column("new_difficulty", sa.Float(), nullable=True),
        sa.Column("new_due_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("undone_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["card_id"], ["card.id"], name="fk_review_log_card_id_card", ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["owner_id"], ["owner.id"], name="fk_review_log_owner_id_owner", ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id", name="pk_review_log"),
    )
    op.create_index("ix_review_log_owner_id_reviewed_at", "review_log", ["owner_id", "reviewed_at"])
    op.create_index("ix_review_log_card_id_reviewed_at", "review_log", ["card_id", "reviewed_at"])


def downgrade() -> None:
    op.drop_table("review_log")
    op.drop_table("audio_clip")
    op.drop_table("card_tag")
    op.drop_table("tag")
    op.execute("DROP INDEX IF EXISTS ix_card_definition_trgm")
    op.execute("DROP INDEX IF EXISTS ix_card_term_trgm")
    op.drop_table("card")
    op.drop_table("owner")
    op.execute("DROP TYPE IF EXISTS review_direction")
    op.execute("DROP TYPE IF EXISTS audio_side")
    op.execute("DROP FUNCTION IF EXISTS f_unaccent(text)")

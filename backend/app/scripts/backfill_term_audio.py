"""Backfill term audio for cards that predate auto-generation.

One-off maintenance script: finds every card missing a term-side audio clip
and generates one, driving `app.services.tts.generate_term_clip` directly —
the exact same code path a new card goes through on creation. Safe to
interrupt and re-run: the query only ever selects cards that still need one,
so nothing is regenerated or duplicated.

    python -m app.scripts.backfill_term_audio              # the real thing
    python -m app.scripts.backfill_term_audio --dry-run     # count only
    python -m app.scripts.backfill_term_audio --limit 20    # try a batch first

The interesting logic (the query, and driving `generate_term_clip` over the
results) lives in `count_cards_missing_term_audio`, `find_cards_missing_term_audio`,
and `backfill` — all three take an already-open session/storage and are unit
tested directly. `main`/`_run_cli` below are just the CLI shell: argument
parsing, opening the real session, and printing.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
from collections.abc import Callable, Iterable
from dataclasses import dataclass

from sqlalchemy import exists, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_storage
from app.core.config import settings
from app.db.session import SessionLocal
from app.models.audio_clip import AudioClip, AudioSide
from app.models.card import Card
from app.services.tts import generate_term_clip
from app.storage.base import Storage

_MISSING_TERM_AUDIO = ~exists().where(
    AudioClip.card_id == Card.id, AudioClip.side == AudioSide.TERM
)


def _candidates_stmt(*, limit: int | None):
    stmt = select(Card).where(Card.deleted_at.is_(None), _MISSING_TERM_AUDIO)
    stmt = stmt.order_by(Card.created_at)
    if limit is not None:
        stmt = stmt.limit(limit)
    return stmt


async def count_cards_missing_term_audio(session: AsyncSession) -> int:
    stmt = select(func.count()).select_from(
        select(Card.id).where(Card.deleted_at.is_(None), _MISSING_TERM_AUDIO).subquery()
    )
    return (await session.execute(stmt)).scalar_one()


async def find_cards_missing_term_audio(
    session: AsyncSession, *, limit: int | None = None
) -> list[Card]:
    rows = await session.execute(_candidates_stmt(limit=limit))
    return list(rows.scalars().all())


@dataclass
class BackfillResult:
    total_missing: int
    processed: int
    generated: int

    @property
    def skipped(self) -> int:
        return self.processed - self.generated


async def backfill(
    session: AsyncSession,
    storage: Storage,
    *,
    limit: int | None = None,
    progress: Callable[[list[Card]], Iterable[Card]] = lambda cards: cards,
) -> BackfillResult:
    """Generates term audio for every card missing it (or the first `limit`).

    `progress` wraps the card list for display — pass `tqdm` from the CLI;
    left as the identity function it's silent, which is what tests want.
    """
    total = await count_cards_missing_term_audio(session)
    cards = await find_cards_missing_term_audio(session, limit=limit)

    generated = 0
    for card in progress(cards):
        if await generate_term_clip(session, storage, card):
            generated += 1

    return BackfillResult(total_missing=total, processed=len(cards), generated=generated)


# --------------------------------------------------------------- CLI shell -
async def _run_cli(*, limit: int | None, dry_run: bool) -> None:
    if not settings.tts_enabled:
        raise SystemExit(
            "ENKA_TTS_ENABLED is false — nothing would be generated. "
            "Set it to true (see .env.example) before running this."
        )

    async with SessionLocal() as session:
        total = await count_cards_missing_term_audio(session)
        if total == 0:
            print("Every card already has term audio. Nothing to do.")
            return
        if dry_run:
            print(f"{total} card(s) are missing term audio. Nothing generated (--dry-run).")
            return

        target = total if limit is None else min(limit, total)
        print(f"Generating term audio for {target} of {total} card(s) missing it...")

        from tqdm import tqdm

        def with_bar(cards: list[Card]) -> Iterable[Card]:
            return tqdm(cards, unit="card", desc="Backfilling term audio")

        storage = get_storage()
        result = await backfill(session, storage, limit=limit, progress=with_bar)
        print(
            f"Done: {result.generated} generated, {result.skipped} skipped "
            f"(no confident language match or a synthesis/storage failure — see logs), "
            f"{result.total_missing - result.processed} left for a future run."
        )


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Count cards missing term audio and exit without generating anything.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        metavar="N",
        help="Only process the first N cards missing term audio (try a small batch first).",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    args = _parse_args(argv)
    logging.basicConfig(level=logging.INFO)
    asyncio.run(_run_cli(limit=args.limit, dry_run=args.dry_run))


if __name__ == "__main__":
    main()

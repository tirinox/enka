"""Block until Postgres accepts our credentials. Run by docker-entrypoint.sh.

Compose's healthcheck already waits for `pg_isready`, but that reports the
server as up a moment before it will actually authenticate connections on a
freshly initialised volume. This closes that window.
"""

from __future__ import annotations

import asyncio
import sys

from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

from app.core.config import settings

ATTEMPTS = 30
DELAY_SECONDS = 1.0


async def wait_for_db() -> bool:
    engine = create_async_engine(settings.database_url, pool_pre_ping=True)
    try:
        for attempt in range(1, ATTEMPTS + 1):
            try:
                async with engine.connect() as conn:
                    await conn.execute(text("SELECT 1"))
                print(f"[wait] database ready after {attempt} attempt(s)")
                return True
            except Exception as exc:
                if attempt == ATTEMPTS:
                    print(f"[wait] giving up after {ATTEMPTS} attempts: {exc}", file=sys.stderr)
                    return False
                await asyncio.sleep(DELAY_SECONDS)
        return False
    finally:
        await engine.dispose()


if __name__ == "__main__":
    sys.exit(0 if asyncio.run(wait_for_db()) else 1)

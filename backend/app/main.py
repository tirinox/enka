from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import select

from app.api.v1 import health
from app.api.v1.router import api_router
from app.core.config import settings
from app.core.errors import register_exception_handlers
from app.core.logging import setup_logging
from app.db.session import SessionLocal, engine
from app.models.owner import Owner

logger = logging.getLogger("enka")

DESCRIPTION = """
Cloud backend for **Enka** — personal flashcards for language study.

Cards are a *term* and its *definition*, either side optionally carrying
native-speaker audio. Scheduling uses **FSRS**, the algorithm behind modern
Anki: answer `again` and the card returns within a minute, answer `easy` and it
moves days or months out.

**Getting started:** `POST /api/v1/auth/token` with the secret from the
server's `.env`, then send the returned JWT as `Authorization: Bearer <token>`.
"""


async def ensure_owner() -> None:
    """Seed the single owner row. Idempotent — safe on every boot."""
    async with SessionLocal() as session:
        owner = (await session.execute(select(Owner).limit(1))).scalar_one_or_none()
        if owner is None:
            owner = Owner(name=settings.owner_name)
            session.add(owner)
            await session.commit()
            logger.info("seeded owner %s (%s)", owner.id, owner.name)
        elif owner.name != settings.owner_name:
            owner.name = settings.owner_name
            await session.commit()


@asynccontextmanager
async def lifespan(_: FastAPI):
    setup_logging(settings.log_level)
    settings.validate_secrets()
    await ensure_owner()
    logger.info("Enka API ready (env=%s)", settings.env)
    yield
    await engine.dispose()


def create_app() -> FastAPI:
    app = FastAPI(
        title="Enka API",
        version=health.VERSION,
        description=DESCRIPTION,
        lifespan=lifespan,
        docs_url="/docs",
        redoc_url="/redoc",
        openapi_url="/openapi.json",
    )

    origins = settings.cors_origin_list
    app.add_middleware(
        CORSMiddleware,
        allow_origins=origins,
        allow_credentials="*" not in origins,
        allow_methods=["*"],
        allow_headers=["*"],
        # So browser clients can read Range/caching headers on audio responses.
        expose_headers=["Content-Range", "Accept-Ranges", "Content-Length", "ETag"],
    )

    register_exception_handlers(app)
    app.include_router(health.router)
    app.include_router(api_router)
    return app


app = create_app()

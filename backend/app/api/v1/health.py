from __future__ import annotations

from datetime import UTC, datetime

from fastapi import APIRouter
from sqlalchemy import text

from app.api.deps import SessionDep
from app.schemas.common import HealthResponse

router = APIRouter(tags=["health"])

VERSION = "0.1.0"


@router.get("/health", response_model=HealthResponse, summary="Liveness and DB connectivity")
async def health(session: SessionDep) -> HealthResponse:
    try:
        await session.execute(text("SELECT 1"))
        database = "ok"
    except Exception:
        database = "unavailable"
    return HealthResponse(
        status="ok" if database == "ok" else "degraded",
        version=VERSION,
        database=database,
        server_time=datetime.now(UTC),
    )

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Query

from app.api.deps import OwnerDep, SessionDep
from app.schemas.stats import HeatmapResponse, StatsResponse
from app.services import stats as stats_service

router = APIRouter(prefix="/stats", tags=["stats"])


@router.get(
    "",
    response_model=StatsResponse,
    summary="Collection, study and scheduling statistics",
)
async def get_stats(
    owner: OwnerDep,
    session: SessionDep,
    leech_limit: Annotated[int, Query(ge=0, le=100)] = 10,
) -> StatsResponse:
    return await stats_service.collect_stats(session, owner.id, leech_limit=leech_limit)


@router.get(
    "/heatmap",
    response_model=HeatmapResponse,
    summary="Daily review counts",
    description="Contribution-graph data. Days with no reviews are omitted.",
)
async def get_heatmap(
    owner: OwnerDep,
    session: SessionDep,
    days: Annotated[int, Query(ge=1, le=1096)] = 365,
) -> HeatmapResponse:
    return await stats_service.collect_heatmap(session, owner.id, days=days)

from fastapi import APIRouter

from app.api.v1 import audio, auth, cards, stats, study, tags

api_router = APIRouter(prefix="/api/v1")
api_router.include_router(auth.router)
api_router.include_router(cards.router)
api_router.include_router(tags.router)
api_router.include_router(audio.router)
api_router.include_router(study.router)
api_router.include_router(stats.router)

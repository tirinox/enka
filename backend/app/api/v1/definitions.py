from __future__ import annotations

from fastapi import APIRouter

from app.api.deps import AIClientDep, OwnerDep
from app.schemas.definitions import DefinitionGenerateRequest, DefinitionGenerateResponse
from app.services import definitions as definitions_service

router = APIRouter(prefix="/definitions", tags=["definitions"])


@router.post(
    "/generate",
    response_model=DefinitionGenerateResponse,
    summary="AI-generate a definition or translation for any term",
    description=(
        "Works on a term you haven't saved as a card yet, not just an "
        "existing one — the Add flow in both clients calls this directly. "
        "Never writes anything; the client saves the result itself if it "
        "wants to keep it."
    ),
)
async def generate(
    payload: DefinitionGenerateRequest,
    owner: OwnerDep,
    ai_client: AIClientDep,
) -> DefinitionGenerateResponse:
    definition = await definitions_service.generate_definition(
        ai_client, payload.term, payload.mode, owner.native_language
    )
    return DefinitionGenerateResponse(definition=definition)

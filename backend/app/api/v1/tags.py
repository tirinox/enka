from __future__ import annotations

import uuid

from fastapi import APIRouter, Response, status
from sqlalchemy import func, select

from app.api.deps import OwnerDep, SessionDep
from app.core.errors import ConflictError, NotFoundError
from app.models.card import Card
from app.models.tag import Tag, card_tag
from app.schemas.tag import TagCreate, TagOut, TagUpdate, TagWithCount

router = APIRouter(prefix="/tags", tags=["tags"])


async def _get_tag(session: SessionDep, owner_id: uuid.UUID, tag_id: uuid.UUID) -> Tag:
    tag = (
        await session.execute(select(Tag).where(Tag.id == tag_id, Tag.owner_id == owner_id))
    ).scalar_one_or_none()
    if tag is None:
        raise NotFoundError(f"No tag with id {tag_id}.")
    return tag


@router.get(
    "",
    response_model=list[TagWithCount],
    summary="List tags with card counts",
)
async def list_tags(owner: OwnerDep, session: SessionDep) -> list[TagWithCount]:
    count = (
        select(func.count())
        .select_from(card_tag)
        .join(Card, Card.id == card_tag.c.card_id)
        .where(card_tag.c.tag_id == Tag.id, Card.deleted_at.is_(None))
        .scalar_subquery()
    )
    rows = (
        await session.execute(
            select(Tag, count.label("card_count"))
            .where(Tag.owner_id == owner.id)
            .order_by(Tag.name_normalized)
        )
    ).all()
    return [
        TagWithCount(
            id=tag.id,
            name=tag.name,
            color=tag.color,
            created_at=tag.created_at,
            card_count=card_count,
        )
        for tag, card_count in rows
    ]


@router.post("", response_model=TagOut, status_code=status.HTTP_201_CREATED, summary="Create a tag")
async def create_tag(payload: TagCreate, owner: OwnerDep, session: SessionDep) -> TagOut:
    normalized = Tag.normalize(payload.name)
    clash = (
        await session.execute(
            select(Tag).where(Tag.owner_id == owner.id, Tag.name_normalized == normalized)
        )
    ).scalar_one_or_none()
    if clash is not None:
        raise ConflictError(f"Tag '{clash.name}' already exists.", {"tag_id": str(clash.id)})

    tag = Tag(
        owner_id=owner.id,
        name=" ".join(payload.name.split()),
        name_normalized=normalized,
        color=payload.color,
    )
    session.add(tag)
    await session.commit()
    await session.refresh(tag)
    return TagOut.model_validate(tag)


@router.patch("/{tag_id}", response_model=TagOut, summary="Rename or recolour a tag")
async def update_tag(
    tag_id: uuid.UUID, payload: TagUpdate, owner: OwnerDep, session: SessionDep
) -> TagOut:
    tag = await _get_tag(session, owner.id, tag_id)
    data = payload.model_dump(exclude_unset=True)

    if data.get("name"):
        normalized = Tag.normalize(data["name"])
        clash = (
            await session.execute(
                select(Tag).where(
                    Tag.owner_id == owner.id,
                    Tag.name_normalized == normalized,
                    Tag.id != tag.id,
                )
            )
        ).scalar_one_or_none()
        if clash is not None:
            raise ConflictError(f"Tag '{clash.name}' already exists.")
        tag.name = " ".join(data["name"].split())
        tag.name_normalized = normalized
    if "color" in data:
        tag.color = data["color"]

    await session.commit()
    await session.refresh(tag)
    return TagOut.model_validate(tag)


@router.delete(
    "/{tag_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Delete a tag",
    description="Removes the label everywhere. The cards themselves are untouched.",
)
async def delete_tag(tag_id: uuid.UUID, owner: OwnerDep, session: SessionDep) -> Response:
    tag = await _get_tag(session, owner.id, tag_id)
    await session.delete(tag)
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)

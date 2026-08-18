"""Import every model so Alembic autogenerate and mapper configuration see them."""

from app.db.base import Base
from app.models.audio_clip import AudioClip, AudioSide
from app.models.card import Card, SrsState
from app.models.owner import Owner
from app.models.review_log import ReviewDirection, ReviewLog
from app.models.tag import Tag, card_tag

__all__ = [
    "AudioClip",
    "AudioSide",
    "Base",
    "Card",
    "Owner",
    "ReviewDirection",
    "ReviewLog",
    "SrsState",
    "Tag",
    "card_tag",
]

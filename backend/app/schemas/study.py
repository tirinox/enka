from __future__ import annotations

import enum
import uuid
from datetime import datetime

from pydantic import BaseModel, Field

from app.models.review_log import ReviewDirection
from app.schemas.card import CardOut


class StudyMode(str, enum.Enum):
    #: Due first, then unseen cards, then the weakest — the everyday default.
    SMART = "smart"
    #: Uniformly random over everything active.
    RANDOM = "random"
    #: Only cards the scheduler says are due now, oldest first.
    DUE = "due"
    #: Weakest cards first even if not due — for cramming before a trip.
    REINFORCE = "reinforce"
    #: Cards never shown before.
    NEW = "new"


class StudyDirection(str, enum.Enum):
    TERM_TO_DEF = "term_to_def"
    DEF_TO_TERM = "def_to_term"
    RANDOM = "random"


class Rating(str, enum.Enum):
    #: "I don't remember this at all" — brings the card back within minutes.
    AGAIN = "again"
    HARD = "hard"
    GOOD = "good"
    EASY = "easy"


class IntervalPreview(BaseModel):
    """What each rating would buy, in words, before it is pressed.

    The four buttons are the only feedback the algorithm ever gives, and it
    arrives after the decision it should have informed. Sending the intervals
    with the card puts them on the buttons instead.
    """

    again: str
    hard: str
    good: str
    easy: str


class StudyCard(BaseModel):
    card: CardOut
    direction: ReviewDirection = Field(
        description="Which side to show first. Echoed back so the client doesn't have to guess."
    )
    mode: StudyMode
    remaining_due: int = Field(description="Cards still due after this one.")
    intervals: IntervalPreview = Field(
        description="When each rating would bring this card back, humanised."
    )


class StudyQueue(BaseModel):
    items: list[StudyCard]
    remaining_due: int


class AnswerRequest(BaseModel):
    rating: Rating
    direction: ReviewDirection | None = None
    elapsed_ms: int | None = Field(default=None, ge=0, description="Time spent on the card.")
    reviewed_at: datetime | None = Field(
        default=None,
        description="When the answer happened. Lets an offline client replay a session later.",
    )


class AnswerResponse(BaseModel):
    card: CardOut
    review_id: uuid.UUID
    #: How far the card just moved — the number you actually want to see.
    interval_seconds: float
    interval_human: str
    remaining_due: int


class UndoResponse(BaseModel):
    card: CardOut
    undone_review_id: uuid.UUID
    intervals: IntervalPreview = Field(
        description=(
            "What each rating would buy now that the answer is undone. Sent "
            "because undo exists in order to answer the card again."
        )
    )

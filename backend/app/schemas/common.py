from __future__ import annotations

import enum
from datetime import datetime

from pydantic import BaseModel


class SortOrder(str, enum.Enum):
    ASC = "asc"
    DESC = "desc"


class CardSort(str, enum.Enum):
    CREATED_AT = "created_at"
    UPDATED_AT = "updated_at"
    DUE_AT = "due_at"
    TERM = "term"
    TIMES_SHOWN = "times_shown"
    STAR_RATING = "star_rating"


class TagMode(str, enum.Enum):
    #: Card carries at least one of the requested tags.
    ANY = "any"
    #: Card carries all of them.
    ALL = "all"


class HealthResponse(BaseModel):
    status: str
    version: str
    database: str
    server_time: datetime

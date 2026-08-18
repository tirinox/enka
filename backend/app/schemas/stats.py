from __future__ import annotations

import uuid
from datetime import date, datetime

from pydantic import BaseModel, Field


class CollectionStats(BaseModel):
    total_cards: int
    cards_without_definition: int = Field(description="Terms still waiting for a meaning.")
    cards_with_audio: int
    suspended_cards: int
    total_tags: int


class StudyStats(BaseModel):
    studied_unique: int = Field(description="Distinct cards shown at least once.")
    never_studied: int
    total_shows: int = Field(description="Sum of every card's display count.")
    total_reviews: int = Field(description="Answers given, from the review log.")
    correct: int
    wrong: int
    accuracy: float | None


class ScheduleStats(BaseModel):
    due_now: int
    due_today: int
    new_count: int
    learning: int
    review: int
    relearning: int
    avg_stability_days: float | None
    avg_difficulty: float | None
    avg_star_rating: float | None


class DailyActivity(BaseModel):
    day: date
    reviews: int
    correct: int


class LeechCard(BaseModel):
    id: uuid.UUID
    term: str
    definition: str | None
    lapses: int
    wrong_count: int
    accuracy: float | None


class StatsResponse(BaseModel):
    collection: CollectionStats
    study: StudyStats
    schedule: ScheduleStats
    reviews_last_30_days: list[DailyActivity]
    current_streak_days: int = Field(description="Consecutive days up to today with a review.")
    longest_streak_days: int
    leeches: list[LeechCard] = Field(description="Cards you keep forgetting, worst first.")
    server_time: datetime


class HeatmapDay(BaseModel):
    day: date
    reviews: int


class HeatmapResponse(BaseModel):
    days: list[HeatmapDay]
    max_reviews: int
    total_reviews: int

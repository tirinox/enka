/**
 * Mirrors the backend's OpenAPI schema at /openapi.json.
 *
 * Hand-written rather than generated: the surface is small enough to read in
 * one sitting, and a generated file would bury the few places where the API's
 * shape actually matters to the UI (nullable definition, tombstones, scores).
 */

export type Rating = 'again' | 'hard' | 'good' | 'easy'
export type ReviewDirection = 'term_to_def' | 'def_to_term'
export type StudyDirection = ReviewDirection | 'random'
export type StudyMode = 'smart' | 'random' | 'due' | 'reinforce' | 'new'
export type AudioSide = 'term' | 'definition'
export type TagMode = 'any' | 'all'
export type SortOrder = 'asc' | 'desc'
export type CardSort =
  | 'created_at'
  | 'updated_at'
  | 'due_at'
  | 'term'
  | 'times_shown'
  | 'star_rating'

/** FSRS card states, as the scheduler numbers them. */
export const SrsState = { learning: 1, review: 2, relearning: 3 } as const
export type SrsStateValue = (typeof SrsState)[keyof typeof SrsState]

export interface AudioClip {
  id: string
  card_id: string
  side: AudioSide
  original_filename: string | null
  content_type: string
  size_bytes: number
  sha256: string
  duration_ms: number | null
  sort_order: number
  created_at: string
  url: string
}

export interface Card {
  id: string
  term: string
  definition: string | null
  notes: string | null
  tags: string[]
  star_rating: number | null
  suspended: boolean
  created_at: string
  updated_at: string
  deleted_at: string | null
  last_shown_at: string | null
  first_studied_at: string | null
  times_shown: number
  correct_count: number
  wrong_count: number
  lapses: number
  accuracy: number | null
  srs_state: SrsStateValue
  stability: number | null
  difficulty: number | null
  due_at: string
  last_review_at: string | null
  retrievability?: number | null
  audio_clips?: AudioClip[]
}

export interface CardCreate {
  term: string
  definition?: string | null
  notes?: string | null
  star_rating?: number | null
  suspended?: boolean
  tags?: string[]
  due_at?: string | null
}

export interface CardUpdate {
  term?: string
  definition?: string | null
  notes?: string | null
  star_rating?: number | null
  suspended?: boolean
  tags?: string[]
  due_at?: string | null
}

export interface Page<T> {
  items: T[]
  total: number
  limit: number
  offset: number
  has_more: boolean
  server_time?: string
}

export interface BulkCreateResult {
  created: Card[]
  skipped_duplicates: string[]
}

export interface SearchHit {
  card: Card
  score: number
  matched_side: string
}

export interface SearchResponse {
  query: string
  exact_match: boolean
  hits: SearchHit[]
}

export interface Tag {
  id: string
  name: string
  color: string | null
  created_at: string
}

export interface TagWithCount extends Tag {
  card_count: number
}

export interface StudyCard {
  card: Card
  direction: ReviewDirection
  mode: StudyMode
  remaining_due: number
}

export interface StudyQueue {
  items: StudyCard[]
  remaining_due: number
}

export interface AnswerRequest {
  rating: Rating
  direction?: ReviewDirection | null
  elapsed_ms?: number | null
  reviewed_at?: string | null
}

export interface AnswerResponse {
  card: Card
  review_id: string
  interval_seconds: number
  interval_human: string
  remaining_due: number
}

export interface UndoResponse {
  card: Card
  undone_review_id: string
}

export interface CollectionStats {
  total_cards: number
  cards_without_definition: number
  cards_with_audio: number
  suspended_cards: number
  total_tags: number
}

export interface StudyStats {
  studied_unique: number
  never_studied: number
  total_shows: number
  total_reviews: number
  correct: number
  wrong: number
  accuracy: number | null
}

export interface ScheduleStats {
  due_now: number
  due_today: number
  new_count: number
  learning: number
  review: number
  relearning: number
  avg_stability_days: number | null
  avg_difficulty: number | null
  avg_star_rating: number | null
}

export interface DailyActivity {
  day: string
  reviews: number
  correct: number
}

export interface LeechCard {
  id: string
  term: string
  definition: string | null
  lapses: number
  wrong_count: number
  accuracy: number | null
}

export interface StatsResponse {
  collection: CollectionStats
  study: StudyStats
  schedule: ScheduleStats
  reviews_last_30_days: DailyActivity[]
  current_streak_days: number
  longest_streak_days: number
  leeches: LeechCard[]
  server_time: string
}

export interface HeatmapDay {
  day: string
  reviews: number
}

export interface HeatmapResponse {
  days: HeatmapDay[]
  max_reviews: number
  total_reviews: number
}

export interface TokenResponse {
  access_token: string
  token_type?: string
  expires_at: string
  scope?: string
}

export interface MeResponse {
  owner_id: string
  name: string
  native_language: string | null
  token_expires_at: string
}

export interface MeUpdate {
  native_language: string
}

export type DefinitionMode = 'same_language' | 'native_language'

export interface DefinitionGenerateResponse {
  definition: string
}

export interface HealthResponse {
  status: string
  version: string
  database: string
  server_time: string
}

export interface CardFilters {
  q?: string
  tags?: string[]
  tag_mode?: TagMode
  has_definition?: boolean
  has_audio?: boolean
  suspended?: boolean
  star_rating?: number
  due_before?: string
  include_deleted?: boolean
  sort?: CardSort
  order?: SortOrder
  limit?: number
  offset?: number
}

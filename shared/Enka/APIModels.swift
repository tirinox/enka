import Foundation

/// Mirrors the backend's OpenAPI schema at `/openapi.json`.
///
/// Hand-written rather than generated, for the same reason the web client's
/// `types.ts` is: the surface is small enough to read in one sitting, and a
/// generated file would bury the few places where the API's shape actually
/// matters to the UI — a nullable definition, tombstones, scores.
///
/// Only the parts the panel shows are modelled. Fields the panel never reads
/// are left out on purpose: `Decodable` ignores what it is not asked for, so
/// the cost of a field here is the cost of keeping it correct, not of parsing.

// MARK: - Enumerations

enum Rating: String, Codable, CaseIterable, Identifiable {
    case again, hard, good, easy
    var id: String { rawValue }

    /// The key that answers with this rating. Matched by position on the
    /// keyboard, not by character — see `StudyKey`.
    var digit: Int {
        switch self {
        case .again: return 1
        case .hard: return 2
        case .good: return 3
        case .easy: return 4
        }
    }

    var title: String {
        switch self {
        case .again: return "Again"
        case .hard: return "Hard"
        case .good: return "Good"
        case .easy: return "Easy"
        }
    }
}

enum ReviewDirection: String, Codable {
    case termToDef = "term_to_def"
    case defToTerm = "def_to_term"
}

enum StudyDirection: String, Codable, CaseIterable, Identifiable {
    case termToDef = "term_to_def"
    case defToTerm = "def_to_term"
    case random
    var id: String { rawValue }

    /// Short enough for the chip in the footer, where there is room for two
    /// words and no more.
    var title: String {
        switch self {
        case .termToDef: return "Term → Def"
        case .defToTerm: return "Def → Term"
        case .random: return "Both ways"
        }
    }
}

enum StudyMode: String, Codable, CaseIterable, Identifiable {
    case smart, due, new, reinforce, random
    var id: String { rawValue }

    var title: String {
        switch self {
        case .smart: return "Smart"
        case .due: return "Due"
        case .new: return "New"
        case .reinforce: return "Reinforce"
        case .random: return "Random"
        }
    }

    /// What the mode does, one line, for the settings tab.
    var blurb: String {
        switch self {
        case .smart: return "Due first, then new words, then the weakest."
        case .due: return "Only what the scheduler says is due."
        case .new: return "Words you have never answered."
        case .reinforce: return "Most-forgotten first, due or not."
        case .random: return "Anything, uniformly."
        }
    }
}

enum AudioSide: String, Codable {
    case term, definition
}

// MARK: - Cards

struct AudioClip: Codable, Identifiable, Hashable {
    let id: String
    let side: AudioSide
    let durationMs: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case side
        case durationMs = "duration_ms"
    }
}

struct Card: Codable, Identifiable, Hashable {
    let id: String
    let term: String
    let definition: String?
    let notes: String?
    let tags: [String]
    let starRating: Int?
    let suspended: Bool
    let timesShown: Int
    let lapses: Int
    let accuracy: Double?
    let dueAt: Date
    let lastReviewAt: Date?
    let audioClips: [AudioClip]?

    enum CodingKeys: String, CodingKey {
        case id, term, definition, notes, tags, suspended, lapses, accuracy
        case starRating = "star_rating"
        case timesShown = "times_shown"
        case dueAt = "due_at"
        case lastReviewAt = "last_review_at"
        case audioClips = "audio_clips"
    }

    /// A card the scheduler has never seen. Worth its own name because the
    /// study pane says so in a corner, and "no last review" reads as an
    /// accident where "new" reads as a fact.
    var isNew: Bool { lastReviewAt == nil }

    func clips(for side: AudioSide) -> [AudioClip] {
        (audioClips ?? []).filter { $0.side == side }
    }
}

struct CardCreate: Encodable {
    var term: String
    var definition: String?
    var notes: String?
    var tags: [String]?
}

struct Page<T: Decodable>: Decodable {
    let items: [T]
    let total: Int
}

// MARK: - Search

struct SearchHit: Decodable, Identifiable {
    let card: Card
    let score: Double
    let matchedSide: String

    var id: String { card.id }

    enum CodingKeys: String, CodingKey {
        case card, score
        case matchedSide = "matched_side"
    }
}

struct SearchResponse: Decodable {
    let query: String
    /// The point of the endpoint: while a phrase is being typed into the add
    /// tab, this says whether the collection already holds it.
    let exactMatch: Bool
    let hits: [SearchHit]

    enum CodingKeys: String, CodingKey {
        case query, hits
        case exactMatch = "exact_match"
    }
}

// MARK: - Tags

struct Tag: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let color: String?
    let cardCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, color
        case cardCount = "card_count"
    }
}

// MARK: - Study

struct StudyCard: Decodable {
    let card: Card
    let direction: ReviewDirection
    let mode: StudyMode
    let remainingDue: Int

    enum CodingKeys: String, CodingKey {
        case card, direction, mode
        case remainingDue = "remaining_due"
    }
}

struct StudyQueue: Decodable {
    let items: [StudyCard]
    let remainingDue: Int

    enum CodingKeys: String, CodingKey {
        case items
        case remainingDue = "remaining_due"
    }
}

struct AnswerRequest: Encodable {
    let rating: Rating
    let direction: ReviewDirection?
    let elapsedMs: Int?

    enum CodingKeys: String, CodingKey {
        case rating, direction
        case elapsedMs = "elapsed_ms"
    }
}

struct AnswerResponse: Decodable {
    let card: Card
    /// Already humanised by the server ("10 minutes", "8 days"), which is
    /// exactly what the panel wants to show and nothing it wants to compute.
    let intervalHuman: String
    let remainingDue: Int

    enum CodingKeys: String, CodingKey {
        case card
        case intervalHuman = "interval_human"
        case remainingDue = "remaining_due"
    }
}

struct UndoResponse: Decodable {
    let card: Card
}

// MARK: - Stats

struct CollectionStats: Decodable {
    let totalCards: Int
    let cardsWithoutDefinition: Int

    enum CodingKeys: String, CodingKey {
        case totalCards = "total_cards"
        case cardsWithoutDefinition = "cards_without_definition"
    }
}

struct StudyStats: Decodable {
    let studiedUnique: Int
    let neverStudied: Int
    let totalReviews: Int
    let accuracy: Double?

    enum CodingKeys: String, CodingKey {
        case studiedUnique = "studied_unique"
        case neverStudied = "never_studied"
        case totalReviews = "total_reviews"
        case accuracy
    }
}

struct ScheduleStats: Decodable {
    let dueNow: Int
    let dueToday: Int
    let newCount: Int
    let learning: Int
    let review: Int
    let relearning: Int

    enum CodingKeys: String, CodingKey {
        case dueNow = "due_now"
        case dueToday = "due_today"
        case newCount = "new_count"
        case learning, review, relearning
    }
}

struct DailyActivity: Decodable, Identifiable {
    let day: String
    let reviews: Int
    let correct: Int
    var id: String { day }
}

struct LeechCard: Decodable, Identifiable {
    let id: String
    let term: String
    let lapses: Int
}

struct StatsResponse: Decodable {
    let collection: CollectionStats
    let study: StudyStats
    let schedule: ScheduleStats
    let reviewsLast30Days: [DailyActivity]
    let currentStreakDays: Int
    let longestStreakDays: Int
    let leeches: [LeechCard]

    enum CodingKeys: String, CodingKey {
        case collection, study, schedule, leeches
        case reviewsLast30Days = "reviews_last_30_days"
        case currentStreakDays = "current_streak_days"
        case longestStreakDays = "longest_streak_days"
    }
}

// MARK: - Auth and health

struct TokenResponse: Decodable {
    let accessToken: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresAt = "expires_at"
    }
}

struct MeResponse: Decodable {
    let name: String
    let nativeLanguage: String?
    let tokenExpiresAt: Date

    enum CodingKeys: String, CodingKey {
        case name
        case nativeLanguage = "native_language"
        case tokenExpiresAt = "token_expires_at"
    }
}

// MARK: - AI-generated definitions

/// Which kind of text to generate for a card's term — mirrors
/// `app.schemas.definitions.DefinitionMode` on the backend.
enum DefinitionMode: String, Encodable {
    case sameLanguage = "same_language"
    case nativeLanguage = "native_language"
}

struct DefinitionGenerateResponse: Decodable {
    let definition: String
}

struct HealthResponse: Decodable {
    let status: String
    let version: String
    let database: String
}

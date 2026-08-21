/**
 * One fetch wrapper for the whole app.
 *
 * The backend answers every failure with the same envelope —
 * `{"error": {"code": ..., "message": ..., "details": {...}}}` — so this is
 * the only place that has to know how to read it. Everything above catches
 * `ApiError` and shows `.message`.
 */

import type {
  AnswerRequest,
  AnswerResponse,
  AudioClip,
  AudioSide,
  BulkCreateResult,
  Card,
  CardCreate,
  CardFilters,
  CardUpdate,
  DefinitionGenerateResponse,
  DefinitionMode,
  HealthResponse,
  HeatmapResponse,
  MeResponse,
  MeUpdate,
  Page,
  SearchResponse,
  StatsResponse,
  StudyCard,
  StudyDirection,
  StudyMode,
  StudyQueue,
  Tag,
  TagMode,
  TagWithCount,
  TokenResponse,
  UndoResponse,
} from './types'

/** Dev goes through Vite's proxy; a build can be pointed anywhere. */
const BASE = (import.meta.env.VITE_API_BASE ?? '').replace(/\/$/, '')
const V1 = `${BASE}/api/v1`

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly details: Record<string, unknown> = {},
  ) {
    super(message)
    this.name = 'ApiError'
  }

  /** The token is gone or expired — the app should bounce to login. */
  get isAuthFailure(): boolean {
    return this.status === 401 || this.status === 403
  }
}

type TokenReader = () => string | null
type AuthFailureHandler = () => void

let readToken: TokenReader = () => null
let onAuthFailure: AuthFailureHandler = () => {}

/** Wired up once by the auth store, so the client stays free of store imports. */
export function configureClient(opts: {
  getToken: TokenReader
  onAuthFailure: AuthFailureHandler
}): void {
  readToken = opts.getToken
  onAuthFailure = opts.onAuthFailure
}

function query(params: Record<string, unknown>): string {
  const sp = new URLSearchParams()
  for (const [key, value] of Object.entries(params)) {
    if (value === undefined || value === null || value === '') continue
    if (Array.isArray(value)) {
      // Repeated key — how FastAPI reads a list from the query string.
      for (const item of value) sp.append(key, String(item))
    } else {
      sp.append(key, String(value))
    }
  }
  const s = sp.toString()
  return s ? `?${s}` : ''
}

async function toApiError(res: Response): Promise<ApiError> {
  let code = 'error'
  let message = `${res.status} ${res.statusText}`
  let details: Record<string, unknown> = {}
  try {
    const body = await res.json()
    const err = body?.error
    if (err) {
      code = err.code ?? code
      message = err.message ?? message
      details = err.details ?? {}
    }
  } catch {
    // Non-JSON body (a proxy error page, say) — the status line will do.
  }
  return new ApiError(res.status, code, message, details)
}

interface RequestOptions {
  method?: string
  body?: unknown
  /** Endpoints reachable before we hold a token. */
  anonymous?: boolean
  signal?: AbortSignal
}

function request<T>(path: string, opts: RequestOptions = {}): Promise<T> {
  return requestAt<T>(`${V1}${path}`, opts)
}

async function requestAt<T>(url: string, opts: RequestOptions = {}): Promise<T> {
  const { method = 'GET', body, anonymous = false, signal } = opts
  const headers: Record<string, string> = { Accept: 'application/json' }

  if (!anonymous) {
    const token = readToken()
    if (!token) {
      onAuthFailure()
      throw new ApiError(401, 'unauthorized', 'Not signed in.')
    }
    headers.Authorization = `Bearer ${token}`
  }

  let payload: BodyInit | undefined
  if (body instanceof FormData) {
    payload = body // let the browser set the multipart boundary
  } else if (body !== undefined) {
    headers['Content-Type'] = 'application/json'
    payload = JSON.stringify(body)
  }

  let res: Response
  try {
    res = await fetch(url, { method, headers, body: payload, signal })
  } catch (cause) {
    if ((cause as Error)?.name === 'AbortError') throw cause
    throw new ApiError(0, 'network_error', 'Cannot reach the server.')
  }

  if (!res.ok) {
    const error = await toApiError(res)
    if (error.isAuthFailure && !anonymous) onAuthFailure()
    throw error
  }

  if (res.status === 204) return undefined as T
  return (await res.json()) as T
}

export const api = {
  health: () => requestAt<HealthResponse>(`${BASE}/health`, { anonymous: true }),

  auth: {
    token: (secret: string) =>
      request<TokenResponse>('/auth/token', {
        method: 'POST',
        body: { secret },
        anonymous: true,
      }),
    /** Short-lived and media-scoped — safe to put in an `<audio src>` URL. */
    mediaToken: () => request<TokenResponse>('/auth/media-token', { method: 'POST' }),
    me: () => request<MeResponse>('/auth/me'),
    updateMe: (patch: MeUpdate) => request<MeResponse>('/auth/me', { method: 'PATCH', body: patch }),
  },

  cards: {
    list: (filters: CardFilters = {}, signal?: AbortSignal) =>
      request<Page<Card>>(`/cards${query(filters as Record<string, unknown>)}`, { signal }),
    get: (id: string) => request<Card>(`/cards/${id}`),
    create: (card: CardCreate) => request<Card>('/cards', { method: 'POST', body: card }),
    update: (id: string, patch: CardUpdate) =>
      request<Card>(`/cards/${id}`, { method: 'PATCH', body: patch }),
    remove: (id: string, hard = false) =>
      request<void>(`/cards/${id}${query({ hard })}`, { method: 'DELETE' }),
    restore: (id: string) => request<Card>(`/cards/${id}/restore`, { method: 'POST' }),
    bulk: (cards: CardCreate[], skipDuplicates = true) =>
      request<BulkCreateResult>(`/cards/bulk${query({ skip_duplicates: skipDuplicates })}`, {
        method: 'POST',
        body: { cards },
      }),
    search: (
      q: string,
      opts: { side?: string; limit?: number; threshold?: number } = {},
      signal?: AbortSignal,
    ) => request<SearchResponse>(`/cards/search${query({ q, ...opts })}`, { signal }),
    /** Never persisted server-side — save the result yourself via `update()`. */
    generateDefinition: (id: string, mode: DefinitionMode) =>
      request<DefinitionGenerateResponse>(`/cards/${id}/definition/generate`, {
        method: 'POST',
        body: { mode },
      }),
  },

  tags: {
    list: () => request<TagWithCount[]>('/tags'),
    create: (name: string, color?: string | null) =>
      request<Tag>('/tags', { method: 'POST', body: { name, color } }),
    update: (id: string, patch: { name?: string; color?: string | null }) =>
      request<Tag>(`/tags/${id}`, { method: 'PATCH', body: patch }),
    remove: (id: string) => request<void>(`/tags/${id}`, { method: 'DELETE' }),
  },

  audio: {
    listForCard: (cardId: string, side?: AudioSide) =>
      request<AudioClip[]>(`/cards/${cardId}/audio${query({ side })}`),
    upload: (cardId: string, side: AudioSide, file: File, durationMs?: number) => {
      const form = new FormData()
      form.append('file', file)
      return request<AudioClip>(
        `/cards/${cardId}/audio${query({ side, duration_ms: durationMs })}`,
        { method: 'POST', body: form },
      )
    },
    remove: (clipId: string) => request<void>(`/audio/${clipId}`, { method: 'DELETE' }),
  },

  study: {
    next: (opts: {
      mode?: StudyMode
      direction?: StudyDirection
      tags?: string[]
      tag_mode?: TagMode
      mark_shown?: boolean
      /**
       * 404s with code `not_found` when nothing matches the filters. Callers
       * should treat that as "queue empty", not as a failure.
       */
    } = {}) => request<StudyCard>(`/study/next${query(opts)}`),
    queue: (opts: {
      mode?: StudyMode
      direction?: StudyDirection
      tags?: string[]
      tag_mode?: TagMode
      limit?: number
    } = {}) => request<StudyQueue>(`/study/queue${query(opts)}`),
    answer: (cardId: string, body: AnswerRequest) =>
      request<AnswerResponse>(`/study/${cardId}/answer`, { method: 'POST', body }),
    undo: (cardId: string) => request<UndoResponse>(`/study/${cardId}/undo`, { method: 'POST' }),
  },

  stats: {
    overview: (leechLimit = 10) =>
      request<StatsResponse>(`/stats${query({ leech_limit: leechLimit })}`),
    heatmap: (days = 365) => request<HeatmapResponse>(`/stats/heatmap${query({ days })}`),
  },
}

/** Absolute URL for an audio clip, carrying a media-scoped token. */
export function audioUrl(clipId: string, mediaToken: string): string {
  return `${V1}/audio/${clipId}${query({ token: mediaToken })}`
}

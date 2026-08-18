/**
 * Media tokens for `<audio src>`.
 *
 * A browser can't put an Authorization header on an audio element, so the API
 * accepts `?token=` — but only a short-lived, media-scoped one. We hold a
 * single token and re-mint it before it lapses rather than per clip.
 */

import { defineStore } from 'pinia'
import { ref } from 'vue'
import { api, audioUrl } from '@/api/client'

/** Re-mint this far ahead of expiry so playback never starts on a dead token. */
const REFRESH_MARGIN_MS = 30_000

export const useMediaStore = defineStore('media', () => {
  const token = ref<string | null>(null)
  const expiresAt = ref<number>(0)
  let inFlight: Promise<string> | null = null

  async function ensureToken(): Promise<string> {
    if (token.value && Date.now() < expiresAt.value - REFRESH_MARGIN_MS) {
      return token.value
    }
    // Collapse concurrent callers — a card with clips on both sides would
    // otherwise mint two tokens for one render.
    if (!inFlight) {
      inFlight = api.auth
        .mediaToken()
        .then((res) => {
          token.value = res.access_token
          expiresAt.value = new Date(res.expires_at).getTime()
          return res.access_token
        })
        .finally(() => {
          inFlight = null
        })
    }
    return inFlight
  }

  async function urlFor(clipId: string): Promise<string> {
    return audioUrl(clipId, await ensureToken())
  }

  function reset() {
    token.value = null
    expiresAt.value = 0
  }

  return { urlFor, ensureToken, reset }
})

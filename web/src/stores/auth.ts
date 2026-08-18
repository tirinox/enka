/**
 * The session. There are no accounts: you type the server's shared secret
 * once and hold a 30-day JWT.
 */

import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import { api, ApiError, configureClient } from '@/api/client'
import type { MeResponse } from '@/api/types'

const TOKEN_KEY = 'enka.token'
const EXPIRY_KEY = 'enka.token_expires_at'

export const useAuthStore = defineStore('auth', () => {
  const token = ref<string | null>(localStorage.getItem(TOKEN_KEY))
  const expiresAt = ref<string | null>(localStorage.getItem(EXPIRY_KEY))
  const owner = ref<MeResponse | null>(null)
  const busy = ref(false)
  const error = ref<string | null>(null)

  const isAuthenticated = computed(() => {
    if (!token.value) return false
    // A token we know is stale is the same as no token — don't make the user
    // discover it by watching a request fail.
    if (expiresAt.value && new Date(expiresAt.value) <= new Date()) return false
    return true
  })

  const daysRemaining = computed(() => {
    if (!expiresAt.value) return null
    const ms = new Date(expiresAt.value).getTime() - Date.now()
    return Math.max(0, Math.floor(ms / 86_400_000))
  })

  function persist(newToken: string | null, newExpiry: string | null) {
    token.value = newToken
    expiresAt.value = newExpiry
    if (newToken && newExpiry) {
      localStorage.setItem(TOKEN_KEY, newToken)
      localStorage.setItem(EXPIRY_KEY, newExpiry)
    } else {
      localStorage.removeItem(TOKEN_KEY)
      localStorage.removeItem(EXPIRY_KEY)
    }
  }

  async function login(secret: string): Promise<boolean> {
    busy.value = true
    error.value = null
    try {
      const res = await api.auth.token(secret)
      persist(res.access_token, res.expires_at)
      owner.value = await api.auth.me()
      return true
    } catch (e) {
      persist(null, null)
      error.value =
        e instanceof ApiError
          ? e.code === 'rate_limited'
            ? 'Too many attempts. Wait a minute and try again.'
            : e.message
          : 'Something went wrong.'
      return false
    } finally {
      busy.value = false
    }
  }

  function logout() {
    persist(null, null)
    owner.value = null
  }

  /** Confirms a stored token is still good, on app start. */
  async function refreshOwner(): Promise<void> {
    if (!token.value) return
    try {
      owner.value = await api.auth.me()
    } catch {
      // configureClient's onAuthFailure has already cleared the session.
    }
  }

  configureClient({
    getToken: () => token.value,
    onAuthFailure: () => {
      persist(null, null)
      owner.value = null
    },
  })

  return {
    token,
    expiresAt,
    owner,
    busy,
    error,
    isAuthenticated,
    daysRemaining,
    login,
    logout,
    refreshOwner,
  }
})

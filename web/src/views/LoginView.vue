<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { api } from '@/api/client'
import { useAuthStore } from '@/stores/auth'

const auth = useAuthStore()
const router = useRouter()
const route = useRoute()

const secret = ref('')
const reveal = ref(false)
const serverVersion = ref<string | null>(null)
const serverReachable = ref<boolean | null>(null)
const input = ref<HTMLInputElement | null>(null)

async function submit() {
  if (!secret.value.trim() || auth.busy) return
  if (await auth.login(secret.value.trim())) {
    const next = route.query.next
    router.push(typeof next === 'string' ? next : { name: 'study' })
  } else {
    secret.value = ''
    input.value?.focus()
  }
}

onMounted(async () => {
  input.value?.focus()
  try {
    const health = await api.health()
    serverVersion.value = health.version
    serverReachable.value = health.status === 'ok' && health.database === 'ok'
  } catch {
    serverReachable.value = false
  }
})
</script>

<template>
  <div class="page">
    <div class="card rise">
      <div class="head">
        <span class="mark">E</span>
        <h1>Enka</h1>
        <p class="tagline">Flashcards for one person's collection.</p>
      </div>

      <form class="form" @submit.prevent="submit">
        <div class="field">
          <label class="label" for="secret">Access secret</label>
          <div class="secret-wrap">
            <input
              id="secret"
              ref="input"
              v-model="secret"
              class="input"
              :type="reveal ? 'text' : 'password'"
              autocomplete="current-password"
              placeholder="from the server's .env"
              spellcheck="false"
            />
            <button
              type="button"
              class="btn btn-ghost btn-sm reveal"
              :aria-label="reveal ? 'Hide secret' : 'Show secret'"
              @click="reveal = !reveal"
            >
              {{ reveal ? '◡' : '◉' }}
            </button>
          </div>
          <p class="hint faint">
            Run <code class="mono">make secret</code> on the server if you don't have it.
          </p>
        </div>

        <p v-if="auth.error" class="error">{{ auth.error }}</p>

        <button class="btn btn-primary submit" type="submit" :disabled="auth.busy || !secret.trim()">
          {{ auth.busy ? 'Checking…' : 'Sign in' }}
        </button>
      </form>

      <div class="status">
        <span class="dot" :class="{ ok: serverReachable, bad: serverReachable === false }" />
        <span v-if="serverReachable === null" class="faint">Contacting the server…</span>
        <span v-else-if="serverReachable" class="faint">
          API reachable · v{{ serverVersion }}
        </span>
        <span v-else class="err-text">Can't reach the API. Is it running?</span>
      </div>
    </div>
  </div>
</template>

<style scoped>
.page {
  display: grid;
  place-items: center;
  min-height: 100dvh;
  padding: var(--sp-5);
  /* A single warm bloom behind the card, so the page isn't a flat rectangle. */
  background:
    radial-gradient(58rem 34rem at 50% -12%, rgb(217 119 87 / 9%), transparent 62%),
    var(--bg);
}

.card {
  width: 100%;
  max-width: 24rem;
  padding: var(--sp-6);
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius-xl);
  box-shadow: var(--shadow-lg);
}

.head {
  text-align: center;
  margin-bottom: var(--sp-6);
}

.mark {
  display: grid;
  place-items: center;
  width: 2.75rem;
  height: 2.75rem;
  margin: 0 auto var(--sp-4);
  border-radius: var(--radius);
  background: var(--accent);
  color: var(--text-inverse);
  font-family: var(--font-serif);
  font-size: var(--text-lg);
  font-weight: 700;
}

h1 {
  font-family: var(--font-serif);
  font-size: var(--text-lg);
  font-weight: 500;
}

.tagline {
  margin-top: var(--sp-1);
  font-size: var(--text-sm);
  color: var(--text-faint);
}

.form {
  display: flex;
  flex-direction: column;
  gap: var(--sp-4);
}

.secret-wrap {
  position: relative;
}

.secret-wrap .input {
  padding-right: 2.5rem;
  font-family: var(--font-mono);
  letter-spacing: 0.02em;
}

.reveal {
  position: absolute;
  right: 0.25rem;
  top: 50%;
  transform: translateY(-50%);
  color: var(--text-faint);
}

.hint {
  font-size: var(--text-xs);
}

.hint code {
  padding: 0.0625rem 0.25rem;
  background: var(--bg-elevated);
  border-radius: var(--radius-sm);
  font-size: 0.95em;
}

.error {
  padding: var(--sp-2) var(--sp-3);
  background: var(--danger-soft);
  border: 1px solid var(--danger);
  border-radius: var(--radius);
  color: var(--danger);
  font-size: var(--text-sm);
}

.submit {
  padding: 0.625rem;
  font-size: var(--text-base);
}

.status {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: var(--sp-2);
  margin-top: var(--sp-5);
  padding-top: var(--sp-4);
  border-top: 1px solid var(--border);
  font-size: var(--text-xs);
}

.dot {
  width: 6px;
  height: 6px;
  border-radius: var(--radius-full);
  background: var(--text-faint);
}

.dot.ok {
  background: var(--success);
}

.dot.bad {
  background: var(--danger);
}

.err-text {
  color: var(--danger);
}
</style>

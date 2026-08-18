<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { api } from '@/api/client'
import { useAuthStore } from '@/stores/auth'
import { useConfirmStore } from '@/stores/confirm'

const auth = useAuthStore()
const confirm = useConfirmStore()
const router = useRouter()

const dueNow = ref<number | null>(null)
const theme = ref(document.documentElement.dataset.theme ?? 'dark')

const nav = [
  { to: '/study', label: 'Study', icon: '◈' },
  { to: '/library', label: 'Library', icon: '▤' },
  { to: '/tags', label: 'Tags', icon: '⌗' },
  { to: '/stats', label: 'Statistics', icon: '◴' },
]

const expiryNote = computed(() => {
  const days = auth.daysRemaining
  if (days === null) return null
  if (days <= 0) return 'Session expires today'
  if (days <= 3) return `Session expires in ${days}d`
  return null
})

function toggleTheme() {
  theme.value = theme.value === 'dark' ? 'light' : 'dark'
  document.documentElement.dataset.theme = theme.value
  localStorage.setItem('enka.theme', theme.value)
}

async function signOut() {
  // Signing out forgets the remembered secret as well as the token, so this
  // costs more than it looks like it does — say so rather than asking a bare
  // "are you sure".
  const ok = await confirm.ask({
    title: 'Sign out?',
    message: auth.remembers
      ? "This device will forget the access secret, so you'll need it again to sign back in."
      : undefined,
    confirmLabel: 'Sign out',
    tone: 'danger',
  })
  if (!ok) return
  auth.logout()
  router.push({ name: 'login' })
}

// A due count in the nav is the one number worth carrying everywhere.
onMounted(async () => {
  try {
    dueNow.value = (await api.stats.overview(0)).schedule.due_now
  } catch {
    // Not worth surfacing — the Study view will report a real problem.
  }
})
</script>

<template>
  <aside class="sidebar">
    <div class="brand">
      <span class="mark">E</span>
      <span class="wordmark">Enka</span>
    </div>

    <nav class="nav">
      <RouterLink v-for="item in nav" :key="item.to" :to="item.to" class="nav-item">
        <span class="icon" aria-hidden="true">{{ item.icon }}</span>
        <span>{{ item.label }}</span>
        <span v-if="item.to === '/study' && dueNow" class="count mono">{{ dueNow }}</span>
      </RouterLink>
    </nav>

    <div class="foot">
      <p v-if="expiryNote" class="expiry">{{ expiryNote }}</p>
      <div class="row">
        <span class="owner truncate" :title="auth.owner?.name ?? ''">
          {{ auth.owner?.name ?? 'signed in' }}
        </span>
        <span class="spacer" />
        <button
          class="btn btn-ghost btn-sm btn-icon"
          :title="theme === 'dark' ? 'Switch to light' : 'Switch to dark'"
          @click="toggleTheme"
        >
          {{ theme === 'dark' ? '☀' : '☾' }}
        </button>
        <button class="btn btn-ghost btn-sm btn-icon" title="Sign out" @click="signOut">⏻</button>
      </div>
    </div>
  </aside>
</template>

<style scoped>
.sidebar {
  display: flex;
  flex-direction: column;
  gap: var(--sp-5);
  padding: var(--sp-5) var(--sp-3) var(--sp-4);
  background: var(--bg-elevated);
  border-right: 1px solid var(--border);
  position: sticky;
  top: 0;
  height: 100dvh;
}

.brand {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  padding: 0 var(--sp-2);
}

.mark {
  display: grid;
  place-items: center;
  width: 1.75rem;
  height: 1.75rem;
  border-radius: var(--radius-sm);
  background: var(--accent);
  color: var(--text-inverse);
  font-family: var(--font-serif);
  font-size: var(--text-base);
  font-weight: 700;
}

.wordmark {
  font-family: var(--font-serif);
  font-size: var(--text-md);
  letter-spacing: 0.01em;
}

.nav {
  display: flex;
  flex-direction: column;
  gap: 2px;
  flex: 1;
}

.nav-item {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  padding: 0.5rem var(--sp-3);
  border-radius: var(--radius);
  color: var(--text-muted);
  font-size: var(--text-sm);
  font-weight: 500;
  transition:
    background var(--fast) var(--ease),
    color var(--fast) var(--ease);
}

.nav-item:hover {
  background: var(--surface-hover);
  color: var(--text);
}

.nav-item.router-link-active {
  background: var(--accent-soft);
  color: var(--accent);
}

.icon {
  width: 1rem;
  text-align: center;
  font-size: var(--text-sm);
  opacity: 0.85;
}

.count {
  margin-left: auto;
  padding: 0 0.375rem;
  border-radius: var(--radius-full);
  background: var(--accent);
  color: var(--text-inverse);
  font-size: var(--text-xs);
  font-weight: 600;
}

.foot {
  display: flex;
  flex-direction: column;
  gap: var(--sp-2);
  padding: var(--sp-3) var(--sp-2) 0;
  border-top: 1px solid var(--border);
}

.expiry {
  font-size: var(--text-xs);
  color: var(--warning);
}

.owner {
  font-size: var(--text-xs);
  color: var(--text-faint);
  min-width: 0;
}

@media (max-width: 860px) {
  .sidebar {
    position: static;
    height: auto;
    flex-direction: row;
    align-items: center;
    gap: var(--sp-4);
    border-right: none;
    border-bottom: 1px solid var(--border);
    padding: var(--sp-3) var(--sp-4);
    overflow-x: auto;
  }

  .wordmark {
    display: none;
  }

  .nav {
    flex-direction: row;
    flex: 1;
  }

  .foot {
    border-top: none;
    padding: 0;
  }

  .owner,
  .expiry {
    display: none;
  }
}
</style>

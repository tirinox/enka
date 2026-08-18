<script setup lang="ts">
/**
 * Paste a list, get cards. One card per line; `term — definition` splits on
 * the first separator, and a line with no separator becomes a term with no
 * definition yet — which the model allows on purpose.
 */
import { computed, ref } from 'vue'
import { ApiError, api } from '@/api/client'
import { useToastStore } from '@/stores/toast'
import type { CardCreate } from '@/api/types'

const emit = defineEmits<{ close: []; added: [] }>()
const toasts = useToastStore()

const raw = ref('')
const sharedTags = ref('')
const skipDuplicates = ref(true)
const busy = ref(false)

/** Any of these, whichever appears first on the line. */
const SEPARATORS = [' — ', ' – ', '\t', ' - ', ' = ', ';', '|']

const parsed = computed<CardCreate[]>(() => {
  const tags = sharedTags.value
    .split(',')
    .map((t) => t.trim())
    .filter(Boolean)

  return raw.value
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      let term = line
      let definition: string | null = null
      for (const sep of SEPARATORS) {
        const i = line.indexOf(sep)
        if (i > 0) {
          term = line.slice(0, i).trim()
          definition = line.slice(i + sep.length).trim() || null
          break
        }
      }
      return { term, definition, tags }
    })
    .filter((c) => c.term.length > 0)
})

async function submit() {
  if (!parsed.value.length || busy.value) return
  busy.value = true
  try {
    const res = await api.cards.bulk(parsed.value, skipDuplicates.value)
    const skipped = res.skipped_duplicates.length
    toasts.success(
      `Added ${res.created.length} card${res.created.length === 1 ? '' : 's'}` +
        (skipped ? ` · skipped ${skipped} duplicate${skipped === 1 ? '' : 's'}` : ''),
    )
    emit('added')
    emit('close')
  } catch (e) {
    if (e instanceof ApiError) toasts.error(e.message)
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="scrim" @click.self="emit('close')">
    <div class="dialog panel rise" role="dialog" aria-modal="true">
      <header class="head">
        <h2>Add many cards</h2>
        <span class="spacer" />
        <button class="btn btn-ghost btn-sm btn-icon" aria-label="Close" @click="emit('close')">
          ✕
        </button>
      </header>

      <div class="body">
        <div class="field">
          <label class="label" for="bulk">One card per line</label>
          <textarea
            id="bulk"
            v-model="raw"
            class="textarea code"
            rows="10"
            placeholder="привет — hello&#10;собака — dog&#10;черепаха"
          />
          <p class="faint hint">
            Split with <code>—</code>, a tab, <code>-</code>, <code>=</code>, <code>;</code> or
            <code>|</code>. A line with no separator becomes a term you can define later.
          </p>
        </div>

        <div class="field">
          <label class="label" for="bulk-tags">Tags for all of them</label>
          <input id="bulk-tags" v-model="sharedTags" class="input" placeholder="russian, animals" />
        </div>

        <label class="check">
          <input v-model="skipDuplicates" type="checkbox" />
          <span>Skip terms I already have</span>
        </label>

        <div v-if="parsed.length" class="preview">
          <p class="label">Preview — {{ parsed.length }} card{{ parsed.length === 1 ? '' : 's' }}</p>
          <ul>
            <li v-for="(c, i) in parsed.slice(0, 6)" :key="i">
              <span class="p-term">{{ c.term }}</span>
              <span v-if="c.definition" class="faint">— {{ c.definition }}</span>
              <span v-else class="faint no-def">no definition</span>
            </li>
          </ul>
          <p v-if="parsed.length > 6" class="faint hint">…and {{ parsed.length - 6 }} more.</p>
        </div>
      </div>

      <footer class="foot">
        <span class="spacer" />
        <button class="btn" @click="emit('close')">Cancel</button>
        <button class="btn btn-primary" :disabled="!parsed.length || busy" @click="submit">
          {{ busy ? 'Adding…' : `Add ${parsed.length || ''}`.trim() }}
        </button>
      </footer>
    </div>
  </div>
</template>

<style scoped>
.scrim {
  position: fixed;
  inset: 0;
  z-index: 60;
  display: grid;
  place-items: center;
  padding: var(--sp-5);
  background: var(--overlay);
}

.dialog {
  display: flex;
  flex-direction: column;
  width: min(38rem, 100%);
  max-height: 90dvh;
  background: var(--bg-elevated);
  box-shadow: var(--shadow-lg);
}

.head {
  display: flex;
  align-items: center;
  padding: var(--sp-4) var(--sp-5);
  border-bottom: 1px solid var(--border);
}

h2 {
  font-family: var(--font-serif);
  font-size: var(--text-md);
  font-weight: 500;
}

.body {
  flex: 1;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: var(--sp-4);
  padding: var(--sp-5);
}

.foot {
  display: flex;
  gap: var(--sp-2);
  padding: var(--sp-4) var(--sp-5);
  border-top: 1px solid var(--border);
  background: var(--surface);
}

.code {
  font-family: var(--font-mono);
  font-size: var(--text-sm);
}

.hint {
  font-size: var(--text-xs);
}

.hint code {
  padding: 0 0.25rem;
  background: var(--surface);
  border-radius: 3px;
}

.check {
  display: flex;
  align-items: center;
  gap: var(--sp-2);
  font-size: var(--text-sm);
  color: var(--text-muted);
  cursor: pointer;
}

.preview {
  padding: var(--sp-3);
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
}

.preview ul {
  list-style: none;
  padding: 0;
  margin-top: var(--sp-2);
  display: flex;
  flex-direction: column;
  gap: 0.125rem;
}

.preview li {
  display: flex;
  gap: var(--sp-2);
  font-size: var(--text-sm);
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
}

.p-term {
  font-family: var(--font-serif);
}

.no-def {
  font-style: italic;
  font-size: var(--text-xs);
  align-self: center;
}
</style>

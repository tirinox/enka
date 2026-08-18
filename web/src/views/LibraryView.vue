<script setup lang="ts">
/**
 * The collection.
 *
 * Two ways to find a card, and they hit different endpoints on purpose:
 * plain filtering uses `GET /cards?q=` (a substring match, paginated), while
 * the search box uses `GET /cards/search` — trigram-backed, accent-insensitive
 * and typo-tolerant, which is what answers "do I already have this word?".
 */
import { computed, onMounted, ref, watch } from 'vue'
import { ApiError, api } from '@/api/client'
import { percent, relativeTime } from '@/composables/format'
import { useKeyboard } from '@/composables/keyboard'
import { useToastStore } from '@/stores/toast'
import BulkAddDialog from '@/components/BulkAddDialog.vue'
import CardEditor from '@/components/CardEditor.vue'
import EmptyState from '@/components/EmptyState.vue'
import PageHeader from '@/components/PageHeader.vue'
import StarRating from '@/components/StarRating.vue'
import TagChip from '@/components/TagChip.vue'
import type { Card, CardSort, SearchHit, SortOrder, TagWithCount } from '@/api/types'

const toasts = useToastStore()

const cards = ref<Card[]>([])
const total = ref(0)
const hasMore = ref(false)
const loading = ref(false)
const allTags = ref<TagWithCount[]>([])

const searchQuery = ref('')
const fuzzy = ref(true)
const fuzzyHits = ref<SearchHit[] | null>(null)
const exactMatch = ref(false)

const selectedTags = ref<string[]>([])
const hasDefinition = ref<boolean | undefined>(undefined)
const hasAudio = ref<boolean | undefined>(undefined)
const suspended = ref<boolean | undefined>(undefined)
const includeDeleted = ref(false)
const sort = ref<CardSort>('created_at')
const order = ref<SortOrder>('desc')
const offset = ref(0)
const LIMIT = 50

const editing = ref<Card | null>(null)
const editorOpen = ref(false)
const bulkOpen = ref(false)
const showFilters = ref(false)
const searchInput = ref<HTMLInputElement | null>(null)

let listAbort: AbortController | null = null
let searchAbort: AbortController | null = null
let searchTimer: ReturnType<typeof setTimeout> | null = null

const filtersActive = computed(
  () =>
    selectedTags.value.length > 0 ||
    hasDefinition.value !== undefined ||
    hasAudio.value !== undefined ||
    suspended.value !== undefined ||
    includeDeleted.value,
)

/** In fuzzy mode the hit list replaces the paginated list entirely. */
const inFuzzyMode = computed(() => fuzzy.value && searchQuery.value.trim().length > 0)
const visible = computed<Card[]>(() =>
  inFuzzyMode.value ? (fuzzyHits.value ?? []).map((h) => h.card) : cards.value,
)

const sorts: { value: CardSort; label: string }[] = [
  { value: 'created_at', label: 'Added' },
  { value: 'updated_at', label: 'Updated' },
  { value: 'due_at', label: 'Due' },
  { value: 'term', label: 'Term' },
  { value: 'times_shown', label: 'Times shown' },
  { value: 'star_rating', label: 'Priority' },
]

async function load(append = false) {
  listAbort?.abort()
  listAbort = new AbortController()
  loading.value = true
  try {
    const page = await api.cards.list(
      {
        q: fuzzy.value ? undefined : searchQuery.value.trim() || undefined,
        tags: selectedTags.value.length ? selectedTags.value : undefined,
        tag_mode: 'any',
        has_definition: hasDefinition.value,
        has_audio: hasAudio.value,
        suspended: suspended.value,
        include_deleted: includeDeleted.value,
        sort: sort.value,
        order: order.value,
        limit: LIMIT,
        offset: append ? offset.value : 0,
      },
      listAbort.signal,
    )
    cards.value = append ? [...cards.value, ...page.items] : page.items
    total.value = page.total
    hasMore.value = page.has_more
    offset.value = page.offset + page.items.length
  } catch (e) {
    if (e instanceof ApiError) toasts.error(e.message)
  } finally {
    loading.value = false
  }
}

async function runFuzzySearch() {
  const q = searchQuery.value.trim()
  if (!q) {
    fuzzyHits.value = null
    return
  }
  searchAbort?.abort()
  searchAbort = new AbortController()
  loading.value = true
  try {
    const res = await api.cards.search(q, { limit: 40, threshold: 0.2 }, searchAbort.signal)
    fuzzyHits.value = res.hits
    exactMatch.value = res.exact_match
  } catch (e) {
    if (e instanceof ApiError) toasts.error(e.message)
  } finally {
    loading.value = false
  }
}

/** Debounced so typing a word doesn't fire a query per keystroke. */
function onSearchInput() {
  if (searchTimer) clearTimeout(searchTimer)
  searchTimer = setTimeout(() => {
    if (fuzzy.value) runFuzzySearch()
    else load()
  }, 220)
}

function openNew() {
  editing.value = null
  editorOpen.value = true
}

function openCard(card: Card) {
  editing.value = card
  editorOpen.value = true
}

function onSaved(card: Card) {
  const i = cards.value.findIndex((c) => c.id === card.id)
  if (i >= 0) cards.value[i] = card
  else refreshAll()
  // Keep the drawer open on the freshly created card so audio can be attached
  // without reopening it.
  editing.value = card
}

function onDeleted(id: string) {
  cards.value = cards.value.filter((c) => c.id !== id)
  total.value = Math.max(0, total.value - 1)
  editorOpen.value = false
  editing.value = null
}

async function restore(card: Card, event: Event) {
  event.stopPropagation()
  try {
    const restored = await api.cards.restore(card.id)
    const i = cards.value.findIndex((c) => c.id === card.id)
    if (i >= 0) cards.value[i] = restored
    toasts.success('Card restored.')
  } catch (e) {
    if (e instanceof ApiError) toasts.error(e.message)
  }
}

function clearFilters() {
  selectedTags.value = []
  hasDefinition.value = undefined
  hasAudio.value = undefined
  suspended.value = undefined
  includeDeleted.value = false
}

function toggleTag(name: string) {
  const i = selectedTags.value.indexOf(name)
  if (i === -1) selectedTags.value.push(name)
  else selectedTags.value.splice(i, 1)
}

/** Cycles undefined → true → false → undefined, so one control covers three states. */
function cycle(current: boolean | undefined): boolean | undefined {
  return current === undefined ? true : current ? false : undefined
}

function triState(value: boolean | undefined, yes: string, no: string): string {
  return value === undefined ? 'any' : value ? yes : no
}

async function refreshAll() {
  await load()
  try {
    allTags.value = await api.tags.list()
  } catch {
    // Tags are a nicety in this view; the list itself is what matters.
  }
}

function srsLabel(card: Card): string {
  if (card.first_studied_at === null) return 'new'
  return card.srs_state === 1 ? 'learning' : card.srs_state === 3 ? 'relearning' : 'review'
}

useKeyboard({
  n: () => openNew(),
  '/': () => searchInput.value?.focus(),
  f: () => (showFilters.value = !showFilters.value),
  escape: () => {
    if (bulkOpen.value) bulkOpen.value = false
    else if (editorOpen.value) editorOpen.value = false
    else if (searchQuery.value) searchQuery.value = ''
  },
})

watch([selectedTags, hasDefinition, hasAudio, suspended, includeDeleted, sort, order], () =>
  load(),
  { deep: true },
)

watch(fuzzy, () => {
  fuzzyHits.value = null
  if (searchQuery.value.trim()) onSearchInput()
  else load()
})

onMounted(refreshAll)
</script>

<template>
  <div class="library">
    <PageHeader
      title="Library"
      :subtitle="
        inFuzzyMode
          ? `${visible.length} match${visible.length === 1 ? '' : 'es'}${exactMatch ? ' · exact match found' : ''}`
          : `${total} card${total === 1 ? '' : 's'}${filtersActive ? ' matching filters' : ''}`
      "
    >
      <template #actions>
        <button class="btn" @click="bulkOpen = true">Paste a list</button>
        <button class="btn btn-primary" @click="openNew">
          New card <span class="kbd">N</span>
        </button>
      </template>
    </PageHeader>

    <!-- Search + filter toggle -->
    <div class="toolbar">
      <div class="search">
        <span class="glyph" aria-hidden="true">⌕</span>
        <input
          ref="searchInput"
          v-model="searchQuery"
          class="input search-input"
          :placeholder="fuzzy ? 'Fuzzy search — typos and accents are fine' : 'Filter by substring'"
          @input="onSearchInput"
        />
        <button
          v-if="searchQuery"
          class="btn btn-ghost btn-sm btn-icon clear"
          aria-label="Clear search"
          @click="searchQuery = ''; fuzzyHits = null; load()"
        >
          ✕
        </button>
      </div>

      <button
        class="btn btn-sm"
        :class="{ on: fuzzy }"
        title="Trigram search: tolerates typos and ignores accents"
        @click="fuzzy = !fuzzy"
      >
        {{ fuzzy ? 'Fuzzy' : 'Exact' }}
      </button>

      <button class="btn btn-sm" :class="{ on: showFilters || filtersActive }" @click="showFilters = !showFilters">
        Filters
        <span v-if="filtersActive" class="dot" />
      </button>

      <span class="spacer" />

      <select v-model="sort" class="select select-sm" aria-label="Sort by">
        <option v-for="s in sorts" :key="s.value" :value="s.value">{{ s.label }}</option>
      </select>
      <button
        class="btn btn-sm btn-icon"
        :title="order === 'desc' ? 'Descending' : 'Ascending'"
        @click="order = order === 'desc' ? 'asc' : 'desc'"
      >
        {{ order === 'desc' ? '↓' : '↑' }}
      </button>
    </div>

    <Transition name="drop">
      <div v-if="showFilters" class="filters panel">
        <div class="filter-group">
          <span class="label">Tags</span>
          <div class="tag-wrap">
            <TagChip
              v-for="t in allTags"
              :key="t.id"
              :name="t.name"
              :color="t.color"
              :count="t.card_count"
              :active="selectedTags.includes(t.name)"
              class="clickable"
              @click="toggleTag(t.name)"
            />
            <p v-if="!allTags.length" class="faint">No tags yet.</p>
          </div>
        </div>

        <div class="filter-group">
          <span class="label">Only show</span>
          <div class="tri-row">
            <button class="tri" @click="hasDefinition = cycle(hasDefinition)">
              Definition <b>{{ triState(hasDefinition, 'yes', 'missing') }}</b>
            </button>
            <button class="tri" @click="hasAudio = cycle(hasAudio)">
              Audio <b>{{ triState(hasAudio, 'yes', 'none') }}</b>
            </button>
            <button class="tri" @click="suspended = cycle(suspended)">
              Suspended <b>{{ triState(suspended, 'only', 'hidden') }}</b>
            </button>
            <label class="tri check">
              <input v-model="includeDeleted" type="checkbox" />
              Show deleted
            </label>
            <button v-if="filtersActive" class="btn btn-ghost btn-sm" @click="clearFilters">
              Clear all
            </button>
          </div>
        </div>
      </div>
    </Transition>

    <!-- List -->
    <div class="list-wrap">
      <EmptyState
        v-if="!loading && !visible.length && (searchQuery || filtersActive)"
        glyph="⌕"
        title="Nothing matches"
        hint="Try a shorter query, turn on fuzzy search, or clear the filters."
      >
        <button class="btn" @click="searchQuery = ''; clearFilters(); load()">Reset</button>
      </EmptyState>

      <EmptyState
        v-else-if="!loading && !visible.length"
        glyph="▤"
        title="No cards yet"
        hint="Add the first word you want to learn. The definition can wait."
      >
        <div class="row">
          <button class="btn" @click="bulkOpen = true">Paste a list</button>
          <button class="btn btn-primary" @click="openNew">New card</button>
        </div>
      </EmptyState>

      <div v-else class="list">
        <article
          v-for="(card, i) in visible"
          :key="card.id"
          class="card-row"
          :class="{ deleted: card.deleted_at, suspended: card.suspended }"
          tabindex="0"
          @click="openCard(card)"
          @keydown.enter="openCard(card)"
        >
          <div class="main">
            <div class="terms">
              <span class="term">{{ card.term }}</span>
              <span v-if="card.definition" class="def truncate">{{ card.definition }}</span>
              <span v-else class="def no-def">no definition yet</span>
            </div>
            <div class="tags">
              <TagChip v-for="t in card.tags" :key="t" :name="t" :active="true" />
            </div>
          </div>

          <div class="side">
            <span
              v-if="inFuzzyMode && fuzzyHits?.[i]"
              class="badge score"
              :title="`Matched on ${fuzzyHits[i].matched_side}`"
            >
              {{ Math.round(fuzzyHits[i].score * 100) }}%
            </span>

            <StarRating :model-value="card.star_rating" readonly />

            <span v-if="card.audio_clips?.length" class="badge" title="Has audio">♪</span>

            <span class="badge state" :class="srsLabel(card)">{{ srsLabel(card) }}</span>

            <span class="due mono" :title="`Due ${relativeTime(card.due_at)}`">
              {{ relativeTime(card.due_at) }}
            </span>

            <span class="acc mono faint" :title="`${card.correct_count} right, ${card.wrong_count} wrong`">
              {{ percent(card.accuracy) }}
            </span>

            <button
              v-if="card.deleted_at"
              class="btn btn-sm restore"
              @click="restore(card, $event)"
            >
              Restore
            </button>
          </div>
        </article>

        <div v-if="!inFuzzyMode && hasMore" class="more">
          <button class="btn" :disabled="loading" @click="load(true)">
            {{ loading ? 'Loading…' : `Load ${Math.min(LIMIT, total - visible.length)} more` }}
          </button>
        </div>
      </div>
    </div>

    <CardEditor
      :card="editing"
      :open="editorOpen"
      :known-tags="allTags"
      @close="editorOpen = false"
      @saved="onSaved"
      @deleted="onDeleted"
    />

    <BulkAddDialog v-if="bulkOpen" @close="bulkOpen = false" @added="refreshAll" />
  </div>
</template>

<style scoped>
.library {
  display: flex;
  flex-direction: column;
  gap: var(--sp-4);
  padding: var(--sp-5);
  max-width: var(--content-max);
  width: 100%;
  margin: 0 auto;
}

/* --- toolbar --- */

.toolbar {
  display: flex;
  align-items: center;
  gap: var(--sp-2);
  flex-wrap: wrap;
}

.search {
  position: relative;
  flex: 1;
  min-width: 14rem;
}

.glyph {
  position: absolute;
  left: 0.6875rem;
  top: 50%;
  transform: translateY(-50%);
  color: var(--text-faint);
  font-size: var(--text-md);
  pointer-events: none;
}

.search-input {
  padding-left: 2.125rem;
  padding-right: 2rem;
}

.clear {
  position: absolute;
  right: 0.25rem;
  top: 50%;
  transform: translateY(-50%);
  color: var(--text-faint);
}

.btn.on {
  background: var(--accent-soft);
  border-color: var(--accent-border);
  color: var(--accent);
}

.dot {
  width: 5px;
  height: 5px;
  border-radius: var(--radius-full);
  background: var(--accent);
}

.select-sm {
  width: auto;
  padding-top: 0.3125rem;
  padding-bottom: 0.3125rem;
  font-size: var(--text-xs);
}

/* --- filters --- */

.filters {
  display: flex;
  flex-direction: column;
  gap: var(--sp-4);
  padding: var(--sp-4);
}

.filter-group {
  display: flex;
  flex-direction: column;
  gap: var(--sp-2);
}

.tag-wrap {
  display: flex;
  flex-wrap: wrap;
  gap: var(--sp-2);
}

.clickable {
  cursor: pointer;
}

.tri-row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: var(--sp-2);
}

.tri {
  display: inline-flex;
  align-items: center;
  gap: var(--sp-2);
  padding: 0.3125rem 0.625rem;
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  background: transparent;
  color: var(--text-muted);
  font-size: var(--text-xs);
  cursor: pointer;
  transition: all var(--fast) var(--ease);
}

.tri:hover {
  border-color: var(--border-strong);
  color: var(--text);
}

.tri b {
  color: var(--accent);
  font-weight: 600;
}

.tri.check {
  gap: var(--sp-2);
}

.drop-enter-active,
.drop-leave-active {
  transition: all var(--normal) var(--ease);
}

.drop-enter-from,
.drop-leave-to {
  opacity: 0;
  transform: translateY(-8px);
}

/* --- list --- */

.list-wrap {
  min-height: 12rem;
}

.list {
  display: flex;
  flex-direction: column;
  border: 1px solid var(--border);
  border-radius: var(--radius-lg);
  overflow: hidden;
}

.card-row {
  display: flex;
  align-items: center;
  gap: var(--sp-4);
  padding: var(--sp-3) var(--sp-4);
  background: var(--surface);
  border-bottom: 1px solid var(--border);
  cursor: pointer;
  transition: background var(--fast) var(--ease);
}

.card-row:last-of-type {
  border-bottom: none;
}

.card-row:hover {
  background: var(--surface-hover);
}

.card-row.deleted {
  opacity: 0.55;
}

.card-row.deleted .term {
  text-decoration: line-through;
}

.card-row.suspended {
  opacity: 0.7;
}

.main {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 0.125rem;
}

.terms {
  display: flex;
  align-items: baseline;
  gap: var(--sp-3);
  min-width: 0;
}

.term {
  font-family: var(--font-serif);
  font-size: var(--text-md);
  white-space: nowrap;
}

.def {
  min-width: 0;
  color: var(--text-muted);
  font-size: var(--text-sm);
}

.no-def {
  color: var(--text-faint);
  font-style: italic;
  font-size: var(--text-xs);
}

.tags {
  display: flex;
  gap: var(--sp-1);
  flex-wrap: wrap;
}

.tags:empty {
  display: none;
}

.side {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  flex: none;
  font-size: var(--text-xs);
}

.score {
  background: var(--accent-soft);
  border-color: var(--accent-border);
  color: var(--accent);
}

.state {
  text-transform: lowercase;
}

.state.new {
  color: var(--accent);
  border-color: var(--accent-border);
}

.state.learning,
.state.relearning {
  color: var(--warning);
}

.state.review {
  color: var(--success);
}

.due {
  min-width: 5.5rem;
  text-align: right;
  color: var(--text-muted);
}

.acc {
  min-width: 2.5rem;
  text-align: right;
}

.restore {
  flex: none;
}

.more {
  display: grid;
  place-items: center;
  padding: var(--sp-4);
  background: var(--surface);
}

@media (max-width: 860px) {
  .side .acc,
  .side .state {
    display: none;
  }

  .terms {
    flex-direction: column;
    gap: 0;
  }
}
</style>

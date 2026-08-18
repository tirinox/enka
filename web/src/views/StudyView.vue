<script setup lang="ts">
/**
 * The study loop.
 *
 * Each card comes from `GET /study/next`, one at a time. The obvious
 * alternative — prefetching with `/study/queue` — is wrong here: answering a
 * card changes the scheduler state the queue was picked from, and `queue`
 * doesn't mark cards as shown. One round-trip per card keeps the picker
 * authoritative.
 */
import { computed, onMounted, ref, watch } from 'vue'
import { ApiError, api } from '@/api/client'
import { useKeyboard } from '@/composables/keyboard'
import { humanInterval, relativeTime } from '@/composables/format'
import { useToastStore } from '@/stores/toast'
import AudioPlayer from '@/components/AudioPlayer.vue'
import EmptyState from '@/components/EmptyState.vue'
import TagChip from '@/components/TagChip.vue'
import type { Rating, StudyCard, StudyDirection, StudyMode, TagWithCount } from '@/api/types'

const toasts = useToastStore()

const current = ref<StudyCard | null>(null)
const revealed = ref(false)
const loading = ref(true)
const exhausted = ref(false)
const answering = ref(false)

const mode = ref<StudyMode>((localStorage.getItem('enka.mode') as StudyMode) ?? 'smart')
const direction = ref<StudyDirection>(
  (localStorage.getItem('enka.direction') as StudyDirection) ?? 'term_to_def',
)
const selectedTags = ref<string[]>([])
const allTags = ref<TagWithCount[]>([])
const showSettings = ref(false)

/** Counters for this sitting only — the server tracks the lifetime numbers. */
const session = ref({ reviewed: 0, correct: 0, again: 0 })
const lastAnswer = ref<{ cardId: string; rating: Rating; interval: string } | null>(null)
const remainingDue = ref(0)

/** When shown a definition first, the answer is the term, and vice versa. */
const prompt = computed(() => {
  if (!current.value) return ''
  const { card, direction: dir } = current.value
  return dir === 'term_to_def' ? card.term : (card.definition ?? card.term)
})

const answer = computed(() => {
  if (!current.value) return null
  const { card, direction: dir } = current.value
  return dir === 'term_to_def' ? card.definition : card.term
})

const promptSide = computed(() =>
  current.value?.direction === 'term_to_def' ? 'term' : 'definition',
)
const answerSide = computed(() =>
  current.value?.direction === 'term_to_def' ? 'definition' : 'term',
)

const promptClips = computed(
  () => current.value?.card.audio_clips?.filter((c) => c.side === promptSide.value) ?? [],
)
const answerClips = computed(
  () => current.value?.card.audio_clips?.filter((c) => c.side === answerSide.value) ?? [],
)

const isNew = computed(() => current.value?.card.first_studied_at === null)

const modes: { value: StudyMode; label: string; hint: string }[] = [
  { value: 'smart', label: 'Smart', hint: 'Due first, then new, then weakest' },
  { value: 'due', label: 'Due', hint: 'Only what the scheduler says is due' },
  { value: 'new', label: 'New', hint: "Cards you've never answered" },
  { value: 'reinforce', label: 'Reinforce', hint: 'Most-forgotten first, for cramming' },
  { value: 'random', label: 'Random', hint: 'Uniform over everything active' },
]

const directions: { value: StudyDirection; label: string }[] = [
  { value: 'term_to_def', label: 'Term → Definition' },
  { value: 'def_to_term', label: 'Definition → Term' },
  { value: 'random', label: 'Random side' },
]

const ratings: { value: Rating; label: string; key: string; hint: string }[] = [
  { value: 'again', label: 'Again', key: '1', hint: "Didn't remember" },
  { value: 'hard', label: 'Hard', key: '2', hint: 'With difficulty' },
  { value: 'good', label: 'Good', key: '3', hint: 'After a pause' },
  { value: 'easy', label: 'Easy', key: '4', hint: 'Instant' },
]

async function loadNext() {
  loading.value = true
  revealed.value = false
  try {
    current.value = await api.study.next({
      mode: mode.value,
      direction: direction.value,
      tags: selectedTags.value.length ? selectedTags.value : undefined,
      tag_mode: 'any',
    })
    remainingDue.value = current.value.remaining_due
    exhausted.value = false
  } catch (e) {
    // A 404 here means "nothing matches these filters", not a failure.
    if (e instanceof ApiError && e.status === 404) {
      current.value = null
      exhausted.value = true
    } else if (e instanceof ApiError) {
      toasts.error(e.message)
    }
  } finally {
    loading.value = false
  }
}

async function rate(rating: Rating) {
  if (!current.value || answering.value) return
  // Rating a card you haven't looked at is almost always a slip.
  if (!revealed.value) return

  answering.value = true
  const cardId = current.value.card.id
  try {
    const res = await api.study.answer(cardId, {
      rating,
      direction: current.value.direction,
    })
    session.value.reviewed++
    if (rating === 'again') session.value.again++
    else session.value.correct++
    lastAnswer.value = {
      cardId,
      rating,
      interval: res.interval_human || humanInterval(res.interval_seconds),
    }
    remainingDue.value = res.remaining_due
    await loadNext()
  } catch (e) {
    if (e instanceof ApiError) toasts.error(e.message)
  } finally {
    answering.value = false
  }
}

async function undo() {
  const last = lastAnswer.value
  if (!last || answering.value) return
  answering.value = true
  try {
    const res = await api.study.undo(last.cardId)
    session.value.reviewed = Math.max(0, session.value.reviewed - 1)
    if (last.rating === 'again') session.value.again = Math.max(0, session.value.again - 1)
    else session.value.correct = Math.max(0, session.value.correct - 1)
    lastAnswer.value = null
    // Put the restored card straight back on screen, already revealed —
    // you undid because you mis-rated it, so you want to rate it again.
    current.value = {
      card: res.card,
      direction: direction.value === 'random' ? 'term_to_def' : direction.value,
      mode: mode.value,
      remaining_due: remainingDue.value,
    }
    revealed.value = true
    exhausted.value = false
    toasts.info('Undone.')
  } catch (e) {
    if (e instanceof ApiError) toasts.error(e.message)
  } finally {
    answering.value = false
  }
}

function playPromptAudio() {
  const clips = revealed.value && answerClips.value.length ? answerClips.value : promptClips.value
  if (!clips.length) return
  // Kept simple: replay by constructing a fresh element via the store URL.
  const el = document.querySelector<HTMLElement>(`[data-clip="${clips[0].id}"]`)
  el?.click()
}

function toggleTag(name: string) {
  const i = selectedTags.value.indexOf(name)
  if (i === -1) selectedTags.value.push(name)
  else selectedTags.value.splice(i, 1)
}

useKeyboard({
  ' ': () => (revealed.value ? rate('good') : (revealed.value = true)),
  enter: () => (revealed.value ? rate('good') : (revealed.value = true)),
  '1': () => rate('again'),
  '2': () => rate('hard'),
  '3': () => rate('good'),
  '4': () => rate('easy'),
  u: () => undo(),
  a: () => playPromptAudio(),
  s: () => (showSettings.value = !showSettings.value),
  escape: () => (showSettings.value = false),
})

watch(mode, (v) => localStorage.setItem('enka.mode', v))
watch(direction, (v) => localStorage.setItem('enka.direction', v))
watch([mode, direction, selectedTags], () => loadNext(), { deep: true })

onMounted(async () => {
  await loadNext()
  try {
    allTags.value = await api.tags.list()
  } catch {
    // Tag filtering is optional; a failure here shouldn't block studying.
  }
})
</script>

<template>
  <div class="study">
    <!-- Status strip: what you're doing, and how it's going. -->
    <div class="strip">
      <button class="chip-btn" @click="showSettings = !showSettings">
        <span class="mono">{{ modes.find((m) => m.value === mode)?.label }}</span>
        <span class="faint">·</span>
        <span class="faint">{{ direction === 'def_to_term' ? 'def→term' : direction === 'random' ? 'mixed' : 'term→def' }}</span>
        <span v-if="selectedTags.length" class="badge badge-accent">{{ selectedTags.length }} tags</span>
        <span class="caret" aria-hidden="true">▾</span>
      </button>

      <span class="spacer" />

      <div class="counters mono">
        <span v-if="remainingDue" class="counter" title="Cards still due">
          <b>{{ remainingDue }}</b><span class="faint">due</span>
        </span>
        <span class="counter" title="Answered this session">
          <b>{{ session.reviewed }}</b><span class="faint">done</span>
        </span>
        <span v-if="session.reviewed" class="counter" title="Accuracy this session">
          <b>{{ Math.round((session.correct / session.reviewed) * 100) }}%</b>
        </span>
      </div>

      <button
        class="btn btn-ghost btn-sm"
        :disabled="!lastAnswer || answering"
        title="Undo the last answer (U)"
        @click="undo"
      >
        Undo
      </button>
    </div>

    <!-- Settings drawer -->
    <Transition name="drop">
      <div v-if="showSettings" class="settings panel">
        <div class="setting">
          <span class="label">Mode</span>
          <div class="opts">
            <button
              v-for="m in modes"
              :key="m.value"
              class="opt"
              :class="{ on: mode === m.value }"
              :title="m.hint"
              @click="mode = m.value"
            >
              {{ m.label }}
            </button>
          </div>
        </div>

        <div class="setting">
          <span class="label">Direction</span>
          <div class="opts">
            <button
              v-for="d in directions"
              :key="d.value"
              class="opt"
              :class="{ on: direction === d.value }"
              @click="direction = d.value"
            >
              {{ d.label }}
            </button>
          </div>
        </div>

        <div v-if="allTags.length" class="setting">
          <span class="label">Tags <span class="faint">(any)</span></span>
          <div class="opts wrap">
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
            <button
              v-if="selectedTags.length"
              class="btn btn-ghost btn-sm"
              @click="selectedTags = []"
            >
              Clear
            </button>
          </div>
        </div>
      </div>
    </Transition>

    <!-- The card -->
    <div class="stage">
      <div v-if="loading" class="loading fade-in">
        <span class="spinner" />
      </div>

      <EmptyState
        v-else-if="exhausted"
        glyph="✧"
        title="Nothing to study here"
        :hint="
          selectedTags.length
            ? 'No cards match these tags right now. Try clearing the filter or another mode.'
            : mode === 'due'
              ? 'Everything due is done. Switch to New or Reinforce to keep going.'
              : 'Add some cards in the Library, or try a different mode.'
        "
      >
        <div class="row" style="margin-top: 0.5rem">
          <button v-if="mode !== 'smart'" class="btn" @click="mode = 'smart'">Smart mode</button>
          <RouterLink to="/library" class="btn btn-primary">Go to Library</RouterLink>
        </div>
      </EmptyState>

      <div v-else-if="current" :key="current.card.id" class="card-wrap rise">
        <div class="meta">
          <span v-if="isNew" class="badge badge-accent">new</span>
          <span v-else class="badge" :title="`Due ${relativeTime(current.card.due_at)}`">
            {{ relativeTime(current.card.due_at) }}
          </span>
          <span v-if="current.card.lapses > 0" class="badge" title="Times forgotten">
            {{ current.card.lapses }}× lapsed
          </span>
          <span v-if="current.card.suspended" class="badge">suspended</span>
          <span class="spacer" />
          <TagChip
            v-for="t in current.card.tags"
            :key="t"
            :name="t"
            :active="true"
          />
        </div>

        <!-- Prompt side -->
        <div class="face prompt">
          <p class="side-label">{{ promptSide }}</p>
          <p class="text" :class="{ big: prompt.length < 40 }">{{ prompt }}</p>
          <div v-if="promptClips.length" class="clips">
            <AudioPlayer
              v-for="c in promptClips"
              :key="c.id"
              :clip="c"
              :data-clip="c.id"
              label="Play"
            />
          </div>
        </div>

        <!-- Answer side -->
        <Transition name="flip">
          <div v-if="revealed" class="face answer">
            <div class="rule" />
            <p class="side-label">{{ answerSide }}</p>
            <p v-if="answer" class="text" :class="{ big: answer.length < 40 }">{{ answer }}</p>
            <p v-else class="text empty-def faint">
              No definition yet — add one from the Library.
            </p>
            <div v-if="answerClips.length" class="clips">
              <AudioPlayer
                v-for="c in answerClips"
                :key="c.id"
                :clip="c"
                :data-clip="c.id"
                label="Play"
              />
            </div>
            <p v-if="current.card.notes" class="notes">{{ current.card.notes }}</p>
          </div>
        </Transition>
      </div>
    </div>

    <!-- Controls -->
    <div v-if="current && !loading" class="controls">
      <button v-if="!revealed" class="btn btn-primary reveal" @click="revealed = true">
        Show answer <span class="kbd">Space</span>
      </button>

      <div v-else class="ratings">
        <button
          v-for="r in ratings"
          :key="r.value"
          class="rate"
          :class="r.value"
          :disabled="answering"
          :title="r.hint"
          @click="rate(r.value)"
        >
          <span class="rate-label">{{ r.label }}</span>
          <span class="kbd">{{ r.key }}</span>
        </button>
      </div>

      <p v-if="lastAnswer" class="last faint">
        Last: <b>{{ lastAnswer.rating }}</b> · next in {{ lastAnswer.interval }}
      </p>
    </div>
  </div>
</template>

<style scoped>
.study {
  display: flex;
  flex-direction: column;
  flex: 1;
  min-height: 100dvh;
  padding: var(--sp-4) var(--sp-5) var(--sp-6);
}

/* --- strip --- */

.strip {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  padding-bottom: var(--sp-3);
  border-bottom: 1px solid var(--border);
}

.chip-btn {
  display: inline-flex;
  align-items: center;
  gap: var(--sp-2);
  padding: 0.3125rem 0.625rem;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  background: var(--bg-elevated);
  color: var(--text-muted);
  font-size: var(--text-xs);
  cursor: pointer;
  transition: all var(--fast) var(--ease);
}

.chip-btn:hover {
  border-color: var(--border-strong);
  color: var(--text);
}

.caret {
  font-size: 0.6em;
  opacity: 0.6;
}

.counters {
  display: flex;
  gap: var(--sp-4);
  font-size: var(--text-xs);
}

.counter {
  display: inline-flex;
  align-items: baseline;
  gap: 0.25rem;
}

.counter b {
  color: var(--text);
  font-size: var(--text-sm);
  font-weight: 600;
}

/* --- settings --- */

.settings {
  display: flex;
  flex-direction: column;
  gap: var(--sp-4);
  margin-top: var(--sp-3);
  padding: var(--sp-4);
}

.setting {
  display: flex;
  flex-direction: column;
  gap: var(--sp-2);
}

.opts {
  display: flex;
  gap: var(--sp-2);
}

.opts.wrap {
  flex-wrap: wrap;
  align-items: center;
}

.opt {
  padding: 0.3125rem 0.625rem;
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  background: transparent;
  color: var(--text-muted);
  font-size: var(--text-xs);
  cursor: pointer;
  transition: all var(--fast) var(--ease);
}

.opt:hover {
  border-color: var(--border-strong);
  color: var(--text);
}

.opt.on {
  background: var(--accent-soft);
  border-color: var(--accent-border);
  color: var(--accent);
}

.clickable {
  cursor: pointer;
}

.drop-enter-active,
.drop-leave-active {
  transition: all var(--normal) var(--ease);
  overflow: hidden;
}

.drop-enter-from,
.drop-leave-to {
  opacity: 0;
  transform: translateY(-8px);
}

/* --- stage --- */

.stage {
  flex: 1;
  display: grid;
  place-items: center;
  padding: var(--sp-6) 0;
  min-height: 0;
}

.card-wrap {
  width: 100%;
  max-width: 44rem;
}

.meta {
  display: flex;
  align-items: center;
  gap: var(--sp-2);
  flex-wrap: wrap;
  margin-bottom: var(--sp-5);
}

.face {
  text-align: center;
}

.side-label {
  font-size: var(--text-xs);
  font-weight: 600;
  color: var(--text-faint);
  text-transform: uppercase;
  letter-spacing: 0.1em;
  margin-bottom: var(--sp-3);
}

.text {
  font-family: var(--font-serif);
  font-size: var(--text-lg);
  line-height: 1.35;
  overflow-wrap: break-word;
}

/* Short prompts get the full display size; long ones stay readable. */
.text.big {
  font-size: var(--text-2xl);
}

.empty-def {
  font-family: var(--font-sans);
  font-size: var(--text-base);
  font-style: italic;
}

.clips {
  display: flex;
  justify-content: center;
  gap: var(--sp-2);
  margin-top: var(--sp-4);
}

.rule {
  width: 3rem;
  height: 1px;
  margin: var(--sp-6) auto var(--sp-5);
  background: var(--border-strong);
}

.notes {
  max-width: 34rem;
  margin: var(--sp-4) auto 0;
  padding: var(--sp-3);
  background: var(--bg-elevated);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  color: var(--text-muted);
  font-size: var(--text-sm);
  text-align: left;
  white-space: pre-wrap;
}

.flip-enter-active {
  transition: all var(--normal) var(--ease);
}

.flip-enter-from {
  opacity: 0;
  transform: translateY(10px);
}

/* --- controls --- */

.controls {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: var(--sp-3);
  min-height: 4.5rem;
}

.reveal {
  padding: 0.625rem 1.25rem;
  font-size: var(--text-base);
}

.reveal .kbd {
  border-color: rgb(0 0 0 / 22%);
  background: rgb(0 0 0 / 12%);
  color: inherit;
  opacity: 0.75;
}

.ratings {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: var(--sp-2);
  width: 100%;
  max-width: 34rem;
}

.rate {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: var(--sp-1);
  padding: var(--sp-3) var(--sp-2);
  border: 1px solid var(--border);
  border-top: 2px solid var(--tone);
  border-radius: var(--radius);
  background: var(--surface);
  cursor: pointer;
  transition: all var(--fast) var(--ease);
}

.rate:hover:not(:disabled) {
  background: color-mix(in srgb, var(--tone) 12%, var(--surface));
  border-color: var(--tone);
  border-top-color: var(--tone);
  transform: translateY(-1px);
}

.rate:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.rate-label {
  font-size: var(--text-sm);
  font-weight: 600;
  color: var(--tone);
}

.rate.again {
  --tone: var(--again);
}

.rate.hard {
  --tone: var(--hard);
}

.rate.good {
  --tone: var(--good);
}

.rate.easy {
  --tone: var(--easy);
}

.last {
  font-size: var(--text-xs);
}

.last b {
  color: var(--text-muted);
  font-weight: 600;
}

/* --- loading --- */

.loading {
  display: grid;
  place-items: center;
  padding: var(--sp-8);
}

.spinner {
  width: 1.5rem;
  height: 1.5rem;
  border: 2px solid var(--border);
  border-top-color: var(--accent);
  border-radius: var(--radius-full);
  animation: spin 700ms linear infinite;
}

@media (max-width: 640px) {
  .study {
    padding: var(--sp-3) var(--sp-4) var(--sp-5);
  }

  .text.big {
    font-size: var(--text-xl);
  }

  .counters {
    gap: var(--sp-3);
  }
}
</style>

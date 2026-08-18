<script setup lang="ts">
/**
 * Create or edit one card, in a right-hand drawer.
 *
 * Audio only exists once a card does — the upload endpoint is
 * `/cards/{id}/audio` — so in create mode the audio section is hidden and
 * appears after the first save.
 */
import { computed, nextTick, ref, watch } from 'vue'
import { ApiError, api } from '@/api/client'
import { bytes, fullDate, percent, relativeTime } from '@/composables/format'
import { useToastStore } from '@/stores/toast'
import AudioPlayer from '@/components/AudioPlayer.vue'
import StarRating from '@/components/StarRating.vue'
import TagChip from '@/components/TagChip.vue'
import type { AudioSide, Card, TagWithCount } from '@/api/types'

const props = defineProps<{ card: Card | null; open: boolean; knownTags: TagWithCount[] }>()
const emit = defineEmits<{ close: []; saved: [Card]; deleted: [string] }>()

const toasts = useToastStore()

const term = ref('')
const definition = ref('')
const notes = ref('')
const stars = ref<number | null>(null)
const suspended = ref(false)
const tags = ref<string[]>([])
const tagDraft = ref('')
const saving = ref(false)
const uploading = ref<AudioSide | null>(null)
const termInput = ref<HTMLInputElement | null>(null)

const isNew = computed(() => props.card === null)

/**
 * "Unsaved changes" is a comparison, not a flag.
 *
 * A boolean set from a watcher can't tell a real edit from `reset()` writing
 * the loaded card into the same refs — it fired on open and after every save,
 * so closing always prompted. Comparing against a snapshot taken whenever the
 * form matches the server can't drift that way.
 */
const baseline = ref('')

function snapshot(): string {
  return JSON.stringify({
    term: term.value.trim(),
    definition: definition.value.trim(),
    notes: notes.value.trim(),
    stars: stars.value,
    suspended: suspended.value,
    tags: [...tags.value].sort(),
  })
}

const dirty = computed(() => snapshot() !== baseline.value)

const canSave = computed(() => term.value.trim().length > 0 && !saving.value)

const suggestions = computed(() => {
  const draft = tagDraft.value.trim().toLowerCase()
  if (!draft) return []
  return props.knownTags
    .filter((t) => t.name.toLowerCase().includes(draft) && !tags.value.includes(t.name))
    .slice(0, 6)
})

function reset() {
  const c = props.card
  term.value = c?.term ?? ''
  definition.value = c?.definition ?? ''
  notes.value = c?.notes ?? ''
  stars.value = c?.star_rating ?? null
  suspended.value = c?.suspended ?? false
  tags.value = [...(c?.tags ?? [])]
  tagDraft.value = ''
  baseline.value = snapshot()
}

watch(
  () => [props.open, props.card?.id],
  async () => {
    if (!props.open) return
    reset()
    await nextTick()
    if (isNew.value) termInput.value?.focus()
  },
  { immediate: true },
)

function addTag(name?: string) {
  const value = (name ?? tagDraft.value).trim()
  if (!value) return
  if (!tags.value.includes(value)) tags.value.push(value)
  tagDraft.value = ''
}

function removeTag(name: string) {
  tags.value = tags.value.filter((t) => t !== name)
}

async function save() {
  if (!canSave.value) return
  saving.value = true
  try {
    // Empty strings mean "no value" here, not "a blank definition".
    const payload = {
      term: term.value.trim(),
      definition: definition.value.trim() || null,
      notes: notes.value.trim() || null,
      star_rating: stars.value,
      suspended: suspended.value,
      tags: tags.value,
    }
    const saved = props.card
      ? await api.cards.update(props.card.id, payload)
      : await api.cards.create(payload)
    baseline.value = snapshot()
    toasts.success(props.card ? 'Card updated.' : 'Card added.')
    emit('saved', saved)
  } catch (e) {
    if (e instanceof ApiError) toasts.error(e.message)
  } finally {
    saving.value = false
  }
}

async function upload(side: AudioSide, event: Event) {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  if (!file || !props.card) return
  uploading.value = side
  try {
    await api.audio.upload(props.card.id, side, file)
    emit('saved', await api.cards.get(props.card.id))
    toasts.success(`Audio attached to the ${side}.`)
  } catch (e) {
    if (e instanceof ApiError) toasts.error(e.message)
  } finally {
    uploading.value = null
    input.value = ''
  }
}

async function removeClip(clipId: string) {
  if (!props.card) return
  try {
    await api.audio.remove(clipId)
    emit('saved', await api.cards.get(props.card.id))
  } catch (e) {
    if (e instanceof ApiError) toasts.error(e.message)
  }
}

async function remove() {
  if (!props.card) return
  if (!confirm(`Delete "${props.card.term}"? You can restore it afterwards.`)) return
  try {
    await api.cards.remove(props.card.id)
    toasts.success('Card deleted.')
    emit('deleted', props.card.id)
  } catch (e) {
    if (e instanceof ApiError) toasts.error(e.message)
  }
}

async function restore() {
  if (!props.card) return
  try {
    emit('saved', await api.cards.restore(props.card.id))
    toasts.success('Card restored.')
  } catch (e) {
    if (e instanceof ApiError) toasts.error(e.message)
  }
}

function tryClose() {
  if (dirty.value && !confirm('Discard unsaved changes?')) return
  emit('close')
}

const clipsFor = (side: AudioSide) =>
  props.card?.audio_clips?.filter((c) => c.side === side) ?? []

const srsLabel = computed(() => {
  const s = props.card?.srs_state
  return s === 1 ? 'learning' : s === 2 ? 'review' : s === 3 ? 'relearning' : '—'
})
</script>

<template>
  <Transition name="drawer">
    <div v-if="open" class="scrim" @click.self="tryClose">
      <aside class="drawer" role="dialog" aria-modal="true">
        <header class="head">
          <h2>{{ isNew ? 'New card' : 'Edit card' }}</h2>
          <span class="spacer" />
          <button class="btn btn-ghost btn-sm btn-icon" aria-label="Close" @click="tryClose">
            ✕
          </button>
        </header>

        <div class="body">
          <div v-if="card?.deleted_at" class="tombstone">
            <span>Deleted {{ relativeTime(card.deleted_at) }}.</span>
            <button class="btn btn-sm" @click="restore">Restore</button>
          </div>

          <div class="field">
            <label class="label" for="term">Term</label>
            <input
              id="term"
              ref="termInput"
              v-model="term"
              class="input serif"
              placeholder="the word you're learning"
              @keydown.meta.enter="save"
            />
          </div>

          <div class="field">
            <label class="label" for="def">
              Definition <span class="faint">— optional, fill it in later</span>
            </label>
            <textarea
              id="def"
              v-model="definition"
              class="textarea serif"
              rows="3"
              placeholder="what it means"
              @keydown.meta.enter="save"
            />
          </div>

          <div class="field">
            <label class="label" for="notes">Notes</label>
            <textarea
              id="notes"
              v-model="notes"
              class="textarea"
              rows="2"
              placeholder="usage, mnemonics, an example sentence"
            />
          </div>

          <div class="field">
            <span class="label">Tags</span>
            <div class="tag-row">
              <TagChip
                v-for="t in tags"
                :key="t"
                :name="t"
                :active="true"
                removable
                @remove="removeTag(t)"
              />
            </div>
            <div class="tag-input-wrap">
              <input
                v-model="tagDraft"
                class="input"
                placeholder="add a tag, press Enter"
                @keydown.enter.prevent="addTag()"
                @keydown.,.prevent="addTag()"
              />
              <div v-if="suggestions.length" class="suggestions">
                <button
                  v-for="s in suggestions"
                  :key="s.id"
                  class="suggestion"
                  @click="addTag(s.name)"
                >
                  {{ s.name }} <span class="faint mono">{{ s.card_count }}</span>
                </button>
              </div>
            </div>
          </div>

          <div class="split">
            <div class="field">
              <span class="label">Priority</span>
              <StarRating v-model="stars" />
            </div>
            <div class="field">
              <span class="label">Suspended</span>
              <label class="toggle">
                <input v-model="suspended" type="checkbox" />
                <span class="track"><span class="knob" /></span>
                <span class="toggle-text faint">
                  {{ suspended ? 'skipped in study' : 'in rotation' }}
                </span>
              </label>
            </div>
          </div>

          <!-- Audio needs a card id, so it only appears once saved. -->
          <section v-if="card" class="audio">
            <span class="label">Audio</span>
            <div v-for="side in (['term', 'definition'] as AudioSide[])" :key="side" class="side">
              <div class="side-head">
                <span class="side-name">{{ side }}</span>
                <label class="btn btn-sm upload">
                  {{ uploading === side ? 'Uploading…' : '+ Add clip' }}
                  <input
                    type="file"
                    accept="audio/*"
                    class="sr-only"
                    :disabled="uploading !== null"
                    @change="upload(side, $event)"
                  />
                </label>
              </div>
              <div v-if="clipsFor(side).length" class="clips">
                <div v-for="clip in clipsFor(side)" :key="clip.id" class="clip-row">
                  <AudioPlayer :clip="clip" compact />
                  <span class="clip-name truncate">
                    {{ clip.original_filename ?? clip.content_type }}
                  </span>
                  <span class="faint mono">{{ bytes(clip.size_bytes) }}</span>
                  <button
                    class="btn btn-ghost btn-sm btn-icon"
                    aria-label="Delete clip"
                    @click="removeClip(clip.id)"
                  >
                    ✕
                  </button>
                </div>
              </div>
              <p v-else class="faint no-clips">No clips.</p>
            </div>
          </section>

          <!-- Scheduling facts, read-only. -->
          <section v-if="card" class="facts">
            <span class="label">Scheduling</span>
            <dl>
              <div><dt>State</dt><dd>{{ srsLabel }}</dd></div>
              <div><dt>Due</dt><dd>{{ relativeTime(card.due_at) }}</dd></div>
              <div><dt>Shown</dt><dd>{{ card.times_shown }}×</dd></div>
              <div>
                <dt>Accuracy</dt>
                <dd>{{ percent(card.accuracy) }}
                  <span class="faint">({{ card.correct_count }}/{{ card.correct_count + card.wrong_count }})</span>
                </dd>
              </div>
              <div><dt>Lapses</dt><dd>{{ card.lapses }}</dd></div>
              <div>
                <dt>Stability</dt>
                <dd>{{ card.stability ? `${card.stability.toFixed(1)}d` : '—' }}</dd>
              </div>
              <div>
                <dt>Difficulty</dt>
                <dd>{{ card.difficulty ? card.difficulty.toFixed(1) : '—' }}</dd>
              </div>
              <div><dt>Created</dt><dd>{{ fullDate(card.created_at) }}</dd></div>
            </dl>
          </section>
        </div>

        <footer class="foot">
          <button
            v-if="card && !card.deleted_at"
            class="btn btn-danger btn-sm"
            @click="remove"
          >
            Delete
          </button>
          <span class="spacer" />
          <button class="btn" @click="tryClose">Cancel</button>
          <button class="btn btn-primary" :disabled="!canSave" @click="save">
            {{ saving ? 'Saving…' : isNew ? 'Add card' : 'Save' }}
          </button>
        </footer>
      </aside>
    </div>
  </Transition>
</template>

<style scoped>
.scrim {
  position: fixed;
  inset: 0;
  z-index: 60;
  background: var(--overlay);
  display: flex;
  justify-content: flex-end;
}

.drawer {
  display: flex;
  flex-direction: column;
  width: min(34rem, 100%);
  height: 100%;
  background: var(--bg-elevated);
  border-left: 1px solid var(--border);
  box-shadow: var(--shadow-lg);
}

.head {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
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
  gap: var(--sp-5);
  padding: var(--sp-5);
}

.foot {
  display: flex;
  align-items: center;
  gap: var(--sp-2);
  padding: var(--sp-4) var(--sp-5);
  border-top: 1px solid var(--border);
  background: var(--surface);
}

.serif {
  font-family: var(--font-serif);
  font-size: var(--text-md);
}

.tombstone {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  padding: var(--sp-3);
  background: var(--danger-soft);
  border: 1px solid var(--danger);
  border-radius: var(--radius);
  font-size: var(--text-sm);
  color: var(--danger);
}

.tombstone .btn {
  margin-left: auto;
}

.tag-row {
  display: flex;
  flex-wrap: wrap;
  gap: var(--sp-2);
}

.tag-row:empty {
  display: none;
}

.tag-input-wrap {
  position: relative;
}

.suggestions {
  position: absolute;
  top: calc(100% + 4px);
  left: 0;
  right: 0;
  z-index: 5;
  display: flex;
  flex-direction: column;
  padding: var(--sp-1);
  background: var(--surface);
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
  box-shadow: var(--shadow);
}

.suggestion {
  display: flex;
  justify-content: space-between;
  padding: 0.3125rem var(--sp-2);
  border: none;
  border-radius: var(--radius-sm);
  background: none;
  color: var(--text-muted);
  font-size: var(--text-sm);
  text-align: left;
  cursor: pointer;
}

.suggestion:hover {
  background: var(--surface-hover);
  color: var(--text);
}

.split {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: var(--sp-5);
}

.toggle {
  display: inline-flex;
  align-items: center;
  gap: var(--sp-2);
  cursor: pointer;
}

.toggle input {
  position: absolute;
  opacity: 0;
  pointer-events: none;
}

.track {
  position: relative;
  width: 2.125rem;
  height: 1.1875rem;
  border-radius: var(--radius-full);
  background: var(--surface-active);
  border: 1px solid var(--border);
  transition: background var(--fast) var(--ease);
}

.knob {
  position: absolute;
  top: 2px;
  left: 2px;
  width: 0.875rem;
  height: 0.875rem;
  border-radius: var(--radius-full);
  background: var(--text-faint);
  transition: all var(--fast) var(--ease);
}

.toggle input:checked + .track {
  background: var(--accent-soft);
  border-color: var(--accent-border);
}

.toggle input:checked + .track .knob {
  left: calc(100% - 1rem);
  background: var(--accent);
}

.toggle-text {
  font-size: var(--text-xs);
}

.audio,
.facts {
  display: flex;
  flex-direction: column;
  gap: var(--sp-3);
  padding-top: var(--sp-4);
  border-top: 1px solid var(--border);
}

.side {
  display: flex;
  flex-direction: column;
  gap: var(--sp-2);
}

.side-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
}

.side-name {
  font-size: var(--text-sm);
  color: var(--text-muted);
  text-transform: capitalize;
}

.upload {
  cursor: pointer;
}

.clips {
  display: flex;
  flex-direction: column;
  gap: var(--sp-1);
}

.clip-row {
  display: flex;
  align-items: center;
  gap: var(--sp-2);
  padding: var(--sp-1) var(--sp-2);
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  font-size: var(--text-xs);
}

.clip-name {
  flex: 1;
  min-width: 0;
  color: var(--text-muted);
}

.no-clips {
  font-size: var(--text-xs);
}

.facts dl {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: var(--sp-2) var(--sp-4);
}

.facts dl > div {
  display: flex;
  justify-content: space-between;
  gap: var(--sp-2);
  padding-bottom: var(--sp-1);
  border-bottom: 1px dotted var(--border);
  font-size: var(--text-xs);
}

.facts dt {
  color: var(--text-faint);
}

.facts dd {
  color: var(--text-muted);
  font-variant-numeric: tabular-nums;
  text-align: right;
}

.drawer-enter-active,
.drawer-leave-active {
  transition: opacity var(--normal) var(--ease);
}

.drawer-enter-active .drawer,
.drawer-leave-active .drawer {
  transition: transform var(--normal) var(--ease);
}

.drawer-enter-from,
.drawer-leave-to {
  opacity: 0;
}

.drawer-enter-from .drawer,
.drawer-leave-to .drawer {
  transform: translateX(100%);
}
</style>

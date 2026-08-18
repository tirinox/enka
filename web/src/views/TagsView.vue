<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { ApiError, api } from '@/api/client'
import { relativeTime, tagColor } from '@/composables/format'
import { useConfirmStore } from '@/stores/confirm'
import { useToastStore } from '@/stores/toast'
import EmptyState from '@/components/EmptyState.vue'
import PageHeader from '@/components/PageHeader.vue'
import type { TagWithCount } from '@/api/types'

const toasts = useToastStore()
const confirm = useConfirmStore()

const tags = ref<TagWithCount[]>([])
const loading = ref(true)
const draftName = ref('')
const draftColor = ref('')
const creating = ref(false)
const editingId = ref<string | null>(null)
const editName = ref('')
const editColor = ref('')

/** A short palette beats a colour picker for something used this casually. */
const PALETTE = [
  '#d97757', '#c9954f', '#77a37b', '#6d94bd',
  '#a87fb5', '#5fa8a0', '#c96b8e', '#8a8f98',
]

const sorted = computed(() => [...tags.value].sort((a, b) => b.card_count - a.card_count))
const totalTagged = computed(() => tags.value.reduce((sum, t) => sum + t.card_count, 0))

async function load() {
  loading.value = true
  try {
    tags.value = await api.tags.list()
  } catch (e) {
    if (e instanceof ApiError) toasts.error(e.message)
  } finally {
    loading.value = false
  }
}

async function create() {
  const name = draftName.value.trim()
  if (!name || creating.value) return
  creating.value = true
  try {
    await api.tags.create(name, draftColor.value || null)
    draftName.value = ''
    draftColor.value = ''
    await load()
    toasts.success(`Tag "${name}" created.`)
  } catch (e) {
    if (e instanceof ApiError) toasts.error(e.message)
  } finally {
    creating.value = false
  }
}

function startEdit(tag: TagWithCount) {
  editingId.value = tag.id
  editName.value = tag.name
  editColor.value = tag.color ?? ''
}

async function saveEdit(tag: TagWithCount) {
  const name = editName.value.trim()
  if (!name) return
  try {
    await api.tags.update(tag.id, { name, color: editColor.value || null })
    editingId.value = null
    await load()
    toasts.success('Tag updated.')
  } catch (e) {
    if (e instanceof ApiError) toasts.error(e.message)
  }
}

async function remove(tag: TagWithCount) {
  const ok = await confirm.ask({
    title: `Delete "${tag.name}"?`,
    message: tag.card_count
      ? `It will be removed from ${tag.card_count} card${tag.card_count === 1 ? '' : 's'}. The cards themselves stay.`
      : undefined,
    confirmLabel: 'Delete tag',
    tone: 'danger',
  })
  if (!ok) return
  try {
    await api.tags.remove(tag.id)
    await load()
    toasts.success('Tag deleted.')
  } catch (e) {
    if (e instanceof ApiError) toasts.error(e.message)
  }
}

onMounted(load)
</script>

<template>
  <div class="tags-view">
    <PageHeader
      title="Tags"
      :subtitle="`${tags.length} tag${tags.length === 1 ? '' : 's'} · ${totalTagged} assignment${totalTagged === 1 ? '' : 's'}`"
    />

    <!-- Create -->
    <form class="create panel" @submit.prevent="create">
      <input
        v-model="draftName"
        class="input"
        placeholder="New tag name"
        maxlength="64"
      />
      <div class="swatches">
        <button
          v-for="c in PALETTE"
          :key="c"
          type="button"
          class="swatch"
          :class="{ on: draftColor === c }"
          :style="{ background: c }"
          :aria-label="`Use colour ${c}`"
          @click="draftColor = draftColor === c ? '' : c"
        />
      </div>
      <button class="btn btn-primary" type="submit" :disabled="!draftName.trim() || creating">
        {{ creating ? 'Adding…' : 'Add tag' }}
      </button>
    </form>

    <EmptyState
      v-if="!loading && !tags.length"
      glyph="⌗"
      title="No tags yet"
      hint="Tags group cards by language, topic, or wherever you met the word. Add one above, or type a new tag straight into any card."
    />

    <div v-else class="list">
      <div v-for="tag in sorted" :key="tag.id" class="tag-row">
        <template v-if="editingId === tag.id">
          <input
            v-model="editName"
            class="input edit-name"
            maxlength="64"
            @keydown.enter="saveEdit(tag)"
            @keydown.esc="editingId = null"
          />
          <div class="swatches">
            <button
              v-for="c in PALETTE"
              :key="c"
              class="swatch"
              :class="{ on: editColor === c }"
              :style="{ background: c }"
              :aria-label="`Use colour ${c}`"
              @click="editColor = editColor === c ? '' : c"
            />
          </div>
          <span class="spacer" />
          <button class="btn btn-sm" @click="editingId = null">Cancel</button>
          <button class="btn btn-primary btn-sm" @click="saveEdit(tag)">Save</button>
        </template>

        <template v-else>
          <span class="dot" :style="{ background: tagColor(tag.name, tag.color) }" />
          <span class="name">{{ tag.name }}</span>
          <RouterLink
            class="count"
            :to="{ path: '/library' }"
            :title="`${tag.card_count} card${tag.card_count === 1 ? '' : 's'}`"
          >
            <span class="mono">{{ tag.card_count }}</span>
            <span class="faint">card{{ tag.card_count === 1 ? '' : 's' }}</span>
          </RouterLink>
          <span class="spacer" />
          <span class="created faint">{{ relativeTime(tag.created_at) }}</span>
          <button class="btn btn-ghost btn-sm" @click="startEdit(tag)">Edit</button>
          <button class="btn btn-ghost btn-sm danger" @click="remove(tag)">Delete</button>
        </template>
      </div>
    </div>
  </div>
</template>

<style scoped>
.tags-view {
  display: flex;
  flex-direction: column;
  gap: var(--sp-4);
  padding: var(--sp-5);
  max-width: 52rem;
  width: 100%;
  margin: 0 auto;
}

.create {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  padding: var(--sp-3);
  flex-wrap: wrap;
}

.create .input {
  flex: 1;
  min-width: 10rem;
}

.swatches {
  display: flex;
  gap: var(--sp-1);
}

.swatch {
  width: 1.125rem;
  height: 1.125rem;
  border: 2px solid transparent;
  border-radius: var(--radius-full);
  cursor: pointer;
  transition: transform var(--fast) var(--ease);
}

.swatch:hover {
  transform: scale(1.15);
}

.swatch.on {
  border-color: var(--text);
}

.list {
  display: flex;
  flex-direction: column;
  border: 1px solid var(--border);
  border-radius: var(--radius-lg);
  overflow: hidden;
}

.tag-row {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  padding: var(--sp-3) var(--sp-4);
  background: var(--surface);
  border-bottom: 1px solid var(--border);
  font-size: var(--text-sm);
}

.tag-row:last-child {
  border-bottom: none;
}

.tag-row:hover {
  background: var(--surface-hover);
}

.dot {
  width: 9px;
  height: 9px;
  flex: none;
  border-radius: var(--radius-full);
}

.name {
  font-weight: 500;
}

.count {
  display: inline-flex;
  align-items: baseline;
  gap: 0.25rem;
  color: var(--text-muted);
  font-size: var(--text-xs);
}

.count:hover {
  color: var(--accent);
}

.created {
  font-size: var(--text-xs);
}

.edit-name {
  max-width: 14rem;
}

.danger:hover {
  color: var(--danger);
}
</style>

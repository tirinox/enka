<script setup lang="ts">
import { computed } from 'vue'
import { tagColor } from '@/composables/format'

const props = defineProps<{
  name: string
  color?: string | null
  count?: number
  active?: boolean
  removable?: boolean
}>()

defineEmits<{ remove: []; click: [] }>()

const hue = computed(() => tagColor(props.name, props.color))
</script>

<template>
  <span class="chip" :class="{ active }" :style="{ '--chip': hue }" @click="$emit('click')">
    <span class="swatch" />
    <span class="name truncate">{{ name }}</span>
    <span v-if="count !== undefined" class="count mono">{{ count }}</span>
    <button v-if="removable" class="x" aria-label="Remove tag" @click.stop="$emit('remove')">
      ✕
    </button>
  </span>
</template>

<style scoped>
.chip {
  display: inline-flex;
  align-items: center;
  gap: var(--sp-2);
  max-width: 14rem;
  padding: 0.125rem 0.5rem;
  border: 1px solid var(--border);
  border-radius: var(--radius-full);
  background: var(--bg-elevated);
  color: var(--text-muted);
  font-size: var(--text-xs);
  line-height: 1.6;
  transition: all var(--fast) var(--ease);
}

.chip.active {
  border-color: var(--chip);
  color: var(--text);
  background: color-mix(in srgb, var(--chip) 16%, transparent);
}

.swatch {
  width: 6px;
  height: 6px;
  flex: none;
  border-radius: var(--radius-full);
  background: var(--chip);
}

.name {
  min-width: 0;
}

.count {
  color: var(--text-faint);
  font-size: 0.95em;
}

.x {
  padding: 0;
  border: none;
  background: none;
  color: var(--text-faint);
  font-size: 0.85em;
  cursor: pointer;
}

.x:hover {
  color: var(--danger);
}
</style>

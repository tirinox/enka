<script setup lang="ts">
const props = withDefaults(
  defineProps<{ modelValue: number | null; readonly?: boolean }>(),
  { readonly: false },
)

const emit = defineEmits<{ 'update:modelValue': [number | null] }>()

function set(n: number) {
  if (props.readonly) return
  // Clicking the current rating clears it — otherwise there's no way back to
  // "unrated" once you've tapped a star.
  emit('update:modelValue', props.modelValue === n ? null : n)
}
</script>

<template>
  <span class="stars" :class="{ readonly }">
    <button
      v-for="n in 5"
      :key="n"
      class="star"
      :class="{ on: (modelValue ?? 0) >= n }"
      :disabled="readonly"
      :aria-label="`${n} star${n === 1 ? '' : 's'}`"
      @click.stop="set(n)"
    >
      ★
    </button>
  </span>
</template>

<style scoped>
.stars {
  display: inline-flex;
  gap: 1px;
}

.star {
  padding: 0 1px;
  border: none;
  background: none;
  color: var(--border-strong);
  font-size: var(--text-sm);
  line-height: 1;
  cursor: pointer;
  transition: color var(--fast) var(--ease);
}

.star.on {
  color: var(--accent);
}

.stars:not(.readonly) .star:hover {
  color: var(--accent-hover);
}

.readonly .star {
  cursor: default;
}
</style>

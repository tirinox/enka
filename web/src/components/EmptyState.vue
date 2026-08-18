<script setup lang="ts">
defineProps<{ glyph?: string; title: string; hint?: string }>()
</script>

<template>
  <div class="empty fade-in">
    <span v-if="glyph" class="glyph" aria-hidden="true">{{ glyph }}</span>
    <h3>{{ title }}</h3>
    <p v-if="hint" class="hint faint">{{ hint }}</p>
    <slot />
  </div>
</template>

<style scoped>
.empty {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: var(--sp-3);
  padding: var(--sp-8) var(--sp-5);
  text-align: center;
}

.glyph {
  font-size: var(--text-xl);
  color: var(--text-faint);
  opacity: 0.6;
}

h3 {
  font-size: var(--text-md);
  font-weight: 500;
}

.hint {
  max-width: 28rem;
  font-size: var(--text-sm);
}
</style>

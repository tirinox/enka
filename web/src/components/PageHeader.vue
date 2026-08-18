<script setup lang="ts">
defineProps<{ title: string; subtitle?: string }>()
</script>

<template>
  <header class="head">
    <div class="titles">
      <h1>{{ title }}</h1>
      <p v-if="subtitle" class="sub faint">{{ subtitle }}</p>
    </div>
    <div class="actions">
      <slot name="actions" />
    </div>
  </header>
</template>

<style scoped>
.head {
  display: flex;
  align-items: flex-end;
  gap: var(--sp-4);
  flex-wrap: wrap;
  padding-bottom: var(--sp-4);
  border-bottom: 1px solid var(--border);
}

.titles {
  flex: 1;
  min-width: 0;
}

h1 {
  font-family: var(--font-serif);
  font-size: var(--text-lg);
  font-weight: 500;
}

.sub {
  margin-top: 0.125rem;
  font-size: var(--text-sm);
}

.actions {
  display: flex;
  align-items: center;
  gap: var(--sp-2);
  flex-wrap: wrap;
}
</style>

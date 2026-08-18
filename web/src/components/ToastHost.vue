<script setup lang="ts">
import { useToastStore } from '@/stores/toast'

const toasts = useToastStore()
</script>

<template>
  <div class="host" role="status" aria-live="polite">
    <TransitionGroup name="toast">
      <div v-for="t in toasts.toasts" :key="t.id" class="toast" :class="t.tone">
        <span class="dot" />
        <span class="msg">{{ t.message }}</span>
        <button class="btn btn-ghost btn-sm close" @click="toasts.dismiss(t.id)">✕</button>
      </div>
    </TransitionGroup>
  </div>
</template>

<style scoped>
.host {
  position: fixed;
  right: var(--sp-5);
  bottom: var(--sp-5);
  z-index: 100;
  display: flex;
  flex-direction: column;
  gap: var(--sp-2);
  pointer-events: none;
}

.toast {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  max-width: 26rem;
  padding: var(--sp-3) var(--sp-3) var(--sp-3) var(--sp-4);
  background: var(--surface);
  border: 1px solid var(--border-strong);
  border-radius: var(--radius);
  box-shadow: var(--shadow-lg);
  font-size: var(--text-sm);
  pointer-events: auto;
}

.dot {
  width: 7px;
  height: 7px;
  flex: none;
  border-radius: var(--radius-full);
  background: var(--text-faint);
}

.success .dot {
  background: var(--success);
}

.error .dot {
  background: var(--danger);
}

.info .dot {
  background: var(--info);
}

.msg {
  flex: 1;
}

.close {
  flex: none;
  color: var(--text-faint);
}

.toast-enter-active,
.toast-leave-active {
  transition: all var(--normal) var(--ease);
}

.toast-enter-from,
.toast-leave-to {
  opacity: 0;
  transform: translateX(16px);
}
</style>

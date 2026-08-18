<script setup lang="ts">
import { nextTick, onBeforeUnmount, ref, watch } from 'vue'
import { useConfirmStore } from '@/stores/confirm'

const store = useConfirmStore()
const confirmButton = ref<HTMLButtonElement | null>(null)

/**
 * Escape is bound on the window, in the capture phase, for as long as the
 * dialog is open.
 *
 * Listening on the dialog element only works while focus is inside it, which
 * stops being true the moment anything else takes focus. Capturing also means
 * a view's own Escape shortcut — closing the Study settings, say — doesn't
 * fire underneath the dialog, since we stop the event before it gets there.
 */
function onKeydown(event: KeyboardEvent) {
  if (event.key !== 'Escape') return
  event.preventDefault()
  event.stopPropagation()
  store.cancel()
}

// Focus the confirm button on open so Enter answers it — one of the things
// the native prompt gave us for free.
watch(
  () => store.open,
  async (open) => {
    if (open) {
      window.addEventListener('keydown', onKeydown, true)
      await nextTick()
      confirmButton.value?.focus()
    } else {
      window.removeEventListener('keydown', onKeydown, true)
    }
  },
)

onBeforeUnmount(() => window.removeEventListener('keydown', onKeydown, true))
</script>

<template>
  <Transition name="confirm">
    <div
      v-if="store.open && store.request"
      class="scrim"
      role="presentation"
      @click.self="store.cancel()"
    >
      <div
        class="dialog"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="confirm-title"
        tabindex="-1"
      >
        <h2 id="confirm-title">{{ store.request.title }}</h2>
        <p v-if="store.request.message" class="message">{{ store.request.message }}</p>

        <div class="actions">
          <button class="btn" @click="store.cancel()">
            {{ store.request.cancelLabel ?? 'Cancel' }}
          </button>
          <button
            ref="confirmButton"
            class="btn"
            :class="store.request.tone === 'danger' ? 'btn-destructive' : 'btn-primary'"
            @click="store.confirm()"
          >
            {{ store.request.confirmLabel ?? 'Confirm' }}
          </button>
        </div>
      </div>
    </div>
  </Transition>
</template>

<style scoped>
.scrim {
  position: fixed;
  inset: 0;
  z-index: 200;
  display: grid;
  place-items: center;
  padding: var(--sp-5);
  background: var(--overlay);
  backdrop-filter: blur(2px);
}

.dialog {
  width: min(24rem, 100%);
  padding: var(--sp-5);
  background: var(--surface);
  border: 1px solid var(--border-strong);
  border-radius: var(--radius-lg);
  box-shadow: var(--shadow-lg);
}

.dialog:focus {
  outline: none;
}

h2 {
  font-family: var(--font-serif);
  font-size: var(--text-md);
  font-weight: 500;
}

.message {
  margin-top: var(--sp-2);
  color: var(--text-muted);
  font-size: var(--text-sm);
  line-height: 1.5;
}

.actions {
  display: flex;
  justify-content: flex-end;
  gap: var(--sp-2);
  margin-top: var(--sp-5);
}

/* Destructive confirms are filled, not outlined — this is the one button in
   the app that should feel heavier than its neighbour. */
.btn-destructive {
  background: var(--danger);
  border-color: var(--danger);
  color: var(--text-inverse);
  font-weight: 600;
}

.btn-destructive:hover:not(:disabled) {
  background: color-mix(in srgb, var(--danger) 84%, black);
  border-color: color-mix(in srgb, var(--danger) 84%, black);
}

.confirm-enter-active,
.confirm-leave-active {
  transition: opacity var(--fast) var(--ease);
}

.confirm-enter-active .dialog,
.confirm-leave-active .dialog {
  transition: transform var(--normal) var(--ease);
}

.confirm-enter-from,
.confirm-leave-to {
  opacity: 0;
}

.confirm-enter-from .dialog,
.confirm-leave-to .dialog {
  transform: translateY(8px) scale(0.98);
}
</style>

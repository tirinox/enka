/** Transient messages, bottom-right. */

import { defineStore } from 'pinia'
import { ref } from 'vue'

export type ToastTone = 'info' | 'success' | 'error'

export interface Toast {
  id: number
  message: string
  tone: ToastTone
}

let nextId = 1

export const useToastStore = defineStore('toast', () => {
  const toasts = ref<Toast[]>([])

  function push(message: string, tone: ToastTone = 'info', ttl = 3600) {
    const id = nextId++
    toasts.value.push({ id, message, tone })
    setTimeout(() => dismiss(id), ttl)
  }

  function dismiss(id: number) {
    toasts.value = toasts.value.filter((t) => t.id !== id)
  }

  return {
    toasts,
    push,
    dismiss,
    info: (m: string) => push(m, 'info'),
    success: (m: string) => push(m, 'success'),
    error: (m: string) => push(m, 'error', 5200),
  }
})

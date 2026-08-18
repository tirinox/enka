/** Window-level shortcuts that stand down while you're typing in a field. */

import { onBeforeUnmount, onMounted } from 'vue'

export type KeyHandler = (event: KeyboardEvent) => void

function isTypingTarget(target: EventTarget | null): boolean {
  const el = target as HTMLElement | null
  if (!el) return false
  const tag = el.tagName
  return (
    tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || el.isContentEditable === true
  )
}

/**
 * `map` is keyed by `event.key` lowercased. Handlers don't fire while a text
 * field has focus, so typing "again" into a card editor never rates a card.
 */
export function useKeyboard(map: Record<string, KeyHandler>): void {
  function onKeydown(event: KeyboardEvent) {
    if (isTypingTarget(event.target)) return
    if (event.metaKey || event.ctrlKey || event.altKey) return
    const handler = map[event.key.toLowerCase()]
    if (!handler) return
    event.preventDefault()
    handler(event)
  }

  onMounted(() => window.addEventListener('keydown', onKeydown))
  onBeforeUnmount(() => window.removeEventListener('keydown', onKeydown))
}

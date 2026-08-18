/**
 * Confirmation prompts, as a promise.
 *
 * One dialog is mounted for the whole app; call sites just await an answer:
 *
 *   if (!(await confirm.ask({ title: 'Delete?', tone: 'danger' }))) return
 *
 * which keeps the shape of the native `confirm()` they replaced, so the
 * call sites read the same way without the browser's chrome.
 */

import { defineStore } from 'pinia'
import { ref, shallowRef } from 'vue'

export interface ConfirmRequest {
  title: string
  message?: string
  confirmLabel?: string
  cancelLabel?: string
  /** `danger` paints the confirm button red, for anything destructive. */
  tone?: 'default' | 'danger'
}

export const useConfirmStore = defineStore('confirm', () => {
  const request = shallowRef<ConfirmRequest | null>(null)
  const open = ref(false)
  let resolver: ((ok: boolean) => void) | null = null

  function ask(req: ConfirmRequest): Promise<boolean> {
    // A second prompt while one is open would strand the first promise
    // forever; answering it "no" keeps every caller unblocked.
    resolver?.(false)
    request.value = req
    open.value = true
    return new Promise<boolean>((resolve) => {
      resolver = resolve
    })
  }

  function settle(ok: boolean) {
    open.value = false
    resolver?.(ok)
    resolver = null
  }

  return { request, open, ask, confirm: () => settle(true), cancel: () => settle(false) }
})

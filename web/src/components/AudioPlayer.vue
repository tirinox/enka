<script setup lang="ts">
/**
 * One clip, one button. The URL is minted lazily on first play so that
 * rendering a long list of cards doesn't mint a token per row.
 */
import { onBeforeUnmount, ref } from 'vue'
import { useMediaStore } from '@/stores/media'
import { clipDuration } from '@/composables/format'
import type { AudioClip } from '@/api/types'

const props = withDefaults(
  defineProps<{ clip: AudioClip; label?: string; compact?: boolean }>(),
  { compact: false },
)

const media = useMediaStore()
const playing = ref(false)
const failed = ref(false)
let audio: HTMLAudioElement | null = null

async function toggle() {
  if (playing.value && audio) {
    audio.pause()
    audio.currentTime = 0
    playing.value = false
    return
  }
  try {
    failed.value = false
    if (!audio) {
      audio = new Audio(await media.urlFor(props.clip.id))
      audio.addEventListener('ended', () => (playing.value = false))
      audio.addEventListener('error', () => {
        playing.value = false
        failed.value = true
      })
    }
    await audio.play()
    playing.value = true
  } catch {
    playing.value = false
    failed.value = true
  }
}

/** Exposed so the Study view can trigger playback from a keyboard shortcut. */
defineExpose({ play: toggle })

onBeforeUnmount(() => {
  audio?.pause()
  audio = null
})
</script>

<template>
  <button
    class="clip"
    :class="{ playing, compact, failed }"
    :title="failed ? 'Could not play this clip' : label || 'Play audio'"
    @click.stop="toggle"
  >
    <span class="glyph" aria-hidden="true">{{ playing ? '❚❚' : '▶' }}</span>
    <span v-if="!compact && label" class="lbl">{{ label }}</span>
    <span v-if="!compact && clip.duration_ms" class="dur mono">
      {{ clipDuration(clip.duration_ms) }}
    </span>
  </button>
</template>

<style scoped>
.clip {
  display: inline-flex;
  align-items: center;
  gap: var(--sp-2);
  padding: 0.3125rem 0.625rem;
  border: 1px solid var(--border);
  border-radius: var(--radius-full);
  background: var(--bg-elevated);
  color: var(--text-muted);
  font-size: var(--text-xs);
  cursor: pointer;
  transition: all var(--fast) var(--ease);
}

.clip:hover {
  border-color: var(--accent-border);
  color: var(--accent);
}

.clip.playing {
  background: var(--accent-soft);
  border-color: var(--accent-border);
  color: var(--accent);
}

.clip.failed {
  border-color: var(--danger);
  color: var(--danger);
}

.compact {
  padding: 0.25rem 0.4375rem;
}

.glyph {
  font-size: 0.6em;
  line-height: 1;
}

.dur {
  color: var(--text-faint);
}
</style>

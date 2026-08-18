<script setup lang="ts">
import { computed, onMounted } from 'vue'
import { useRoute } from 'vue-router'
import AppSidebar from '@/components/AppSidebar.vue'
import ConfirmDialog from '@/components/ConfirmDialog.vue'
import ToastHost from '@/components/ToastHost.vue'
import { useAuthStore } from '@/stores/auth'

const auth = useAuthStore()
const route = useRoute()

// The login screen owns the whole viewport; everything else sits beside the nav.
const chromeless = computed(() => route.meta.public === true)

onMounted(() => auth.refreshOwner())
</script>

<template>
  <div :class="chromeless ? 'shell shell-bare' : 'shell'">
    <AppSidebar v-if="!chromeless" />
    <main class="content">
      <RouterView v-slot="{ Component }">
        <Transition name="view" mode="out-in">
          <component :is="Component" />
        </Transition>
      </RouterView>
    </main>
    <ConfirmDialog />
    <ToastHost />
  </div>
</template>

<style scoped>
.shell {
  display: grid;
  grid-template-columns: var(--sidebar-w) 1fr;
  min-height: 100dvh;
}

.shell-bare {
  grid-template-columns: 1fr;
}

.content {
  min-width: 0;
  display: flex;
  flex-direction: column;
}

.view-enter-active,
.view-leave-active {
  transition:
    opacity var(--fast) var(--ease),
    transform var(--fast) var(--ease);
}

.view-enter-from {
  opacity: 0;
  transform: translateY(6px);
}

.view-leave-to {
  opacity: 0;
}

@media (max-width: 860px) {
  .shell {
    grid-template-columns: 1fr;
    grid-template-rows: auto 1fr;
  }
}
</style>

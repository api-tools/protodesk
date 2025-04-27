<script setup lang="ts">
import { computed } from 'vue'
import { useServerProfileStore } from '@/stores/serverProfile'
import { IsServerConnected } from '@wailsjs/go/app/App'
import { ref, watchEffect } from 'vue'

const profileStore = useServerProfileStore()
const activeProfile = computed(() => profileStore.activeProfile)
const status = ref<'connected' | 'disconnected' | 'none'>('none')

watchEffect(async () => {
  if (!activeProfile.value) {
    status.value = 'none'
    return
  }
  try {
    const connected = await IsServerConnected(activeProfile.value.id)
    status.value = connected ? 'connected' : 'disconnected'
  } catch {
    status.value = 'disconnected'
  }
})
</script>

<template>
  <div class="status-bar">
    <span v-if="status === 'none'">No server selected</span>
    <span v-else-if="status === 'connected'" class="text-green-600 font-bold">Connected</span>
    <span v-else class="text-red-600 font-bold">Disconnected</span>
  </div>
</template>

<style scoped>
.status-bar {
  position: fixed;
  left: 0;
  right: 0;
  bottom: 0;
  height: 28px;
  background: #232b36;
  color: #b0bec5;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 0.85rem;
  border-top: 1px solid #2c3e50;
  z-index: 50;
}
</style> 
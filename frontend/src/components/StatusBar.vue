<script setup lang="ts">
import { defineProps, computed } from 'vue'

const props = defineProps({
  connectionStatus: {
    type: String,
    required: true
  },
  selectedProfileId: {
    type: String,
    required: false
  },
  profiles: {
    type: Array,
    required: true
  }
})

const selectedProfileName = computed(() => {
  if (!props.selectedProfileId) return ''
  const profile = (props.profiles as Array<{ id: string; name: string }>).find(
    (p) => p.id === props.selectedProfileId
  )
  return profile ? profile.name : ''
})
</script>

<template>
  <div class="status-bar w-full px-4 py-2 bg-gray-900 text-white text-xs border-t border-gray-700" style="text-align: left;">
    <span v-if="props.connectionStatus === 'connected' && selectedProfileName">
      Connected to {{ selectedProfileName }}
    </span>
    <span v-else-if="props.connectionStatus === 'not_connected' && selectedProfileName">
      Not Connected to {{ selectedProfileName }}
    </span>
    <span v-else>
      Status: Unknown
    </span>
  </div>
</template>

<style scoped>
.status-bar {
  background: #232b36;
  color: #b0bec5;
  display: flex;
  align-items: center;
  justify-content: flex-start;
  font-size: 0.85rem;
  border-top: 1px solid #2c3e50;
  width: 100%;
  position: static;
  left: 0;
  right: 0;
  bottom: 0;
  z-index: 50;
}
</style> 
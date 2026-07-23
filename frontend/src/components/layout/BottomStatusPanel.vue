<script setup lang="ts">
import {computed} from 'vue'
import type {StatusMessage} from '../../types/grpc'

const props = defineProps<{
  status: StatusMessage
}>()

const invokeStatusParts = computed(() => {
  if (props.status.level !== 'success' && props.status.level !== 'error') {
    return null
  }
  const parts = props.status.message.split(' · ')
  if (parts.length < 3 || !parts[parts.length - 1].endsWith(' ms')) {
    return null
  }
  return {
    prefix: parts.slice(0, -2).join(' · '),
    result: parts.slice(-2).join(' · '),
  }
})
</script>

<template>
  <footer class="bottom-status-panel" :data-level="status.level">
    <span class="status-dot" aria-hidden="true"></span>
    <span v-if="invokeStatusParts" class="bottom-status-message">
      <span>{{ invokeStatusParts.prefix }}</span>
      <span class="bottom-status-result">{{ invokeStatusParts.result }}</span>
    </span>
    <span v-else>{{ status.message }}</span>
  </footer>
</template>

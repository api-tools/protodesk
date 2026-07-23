<script setup lang="ts">
import {computed, ref} from 'vue'
import {Copy, History, Search} from '@lucide/vue'
import {ClipboardSetText} from '../../../wailsjs/runtime/runtime'
import type {GrpcResponse} from '../../types/grpc'
import JsonTree from './JsonTree.vue'

const props = defineProps<{
  response: GrpcResponse | null
  isInvoking: boolean
}>()

defineEmits<{
  openHistory: []
}>()

const searchQuery = ref('')
const copyStatus = ref('')
const parsedResponse = computed(() => {
  try {
    return JSON.parse(props.response?.bodyJson || '{}')
  } catch {
    return props.response?.bodyJson || ''
  }
})
const normalizedSearch = computed(() => searchQuery.value.trim().toLowerCase())
const responseMatchCount = computed(() => {
  if (!normalizedSearch.value || !props.response) return 0
  return countMatches(parsedResponse.value, normalizedSearch.value)
})

async function copyResponseBody() {
  if (!props.response) return
  await ClipboardSetText(props.response.bodyJson || '{}')
  copyStatus.value = 'copied'
  window.setTimeout(() => {
    copyStatus.value = ''
  }, 1200)
}

function countMatches(value: unknown, query: string, key = ''): number {
  let count = key.toLowerCase().includes(query) ? 1 : 0
  if (value && typeof value === 'object') {
    return count + Object.entries(value as Record<string, unknown>).reduce((total, [childKey, childValue]) => {
      return total + countMatches(childValue, query, childKey)
    }, 0)
  }
  return count + (String(value).toLowerCase().includes(query) ? 1 : 0)
}
</script>

<template>
  <section class="panel right-panel">
    <div class="panel-header response-header">
      <h2>Response</h2>
      <label class="method-search-wrap response-search-wrap">
        <Search :size="14" aria-hidden="true" />
        <input v-model="searchQuery" type="search" placeholder="Search response">
      </label>
    </div>

    <div v-if="isInvoking" class="empty-state">
      <strong>Invoking method...</strong>
    </div>

    <div v-else-if="!response" class="empty-state">
      <strong>No response yet.</strong>
      <span>Invoke a method to see the gRPC response here.</span>
    </div>

    <div v-else class="response-stack">
      <section v-if="response.error" class="error-message">
        {{ response.error }}
      </section>
      <JsonTree class="response-body-tree" :value="parsedResponse" :query="searchQuery" root />
    </div>

    <footer class="response-status-bar">
      <span v-if="normalizedSearch">{{ responseMatchCount }} matches</span>
      <button class="response-copy-button history-footer-button" type="button" aria-label="Open invocation history" @click="$emit('openHistory')">
        <History :size="14" aria-hidden="true" />
      </button>
      <button v-if="response" class="response-copy-button" type="button" aria-label="Copy response body" @click="copyResponseBody">
        <Copy :size="14" aria-hidden="true" />
        <span v-if="copyStatus">{{ copyStatus }}</span>
      </button>
    </footer>
  </section>
</template>

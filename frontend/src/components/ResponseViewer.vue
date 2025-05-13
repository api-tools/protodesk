<script setup lang="ts">
import { defineProps, computed, ref } from 'vue'

const props = defineProps<{
  responseData: any
  sendLoading: boolean
  sendError?: string
  selectedService?: string
  selectedMethod?: string
  responseTime?: number
  responseSize?: number
}>()

const searchQuery = ref('')
const currentMatchIndex = ref(-1)

const searchResults = computed(() => {
  if (!searchQuery.value || searchQuery.value.length < 2 || !props.responseData) return { count: 0, matches: [] }
  
  const json = JSON.stringify(props.responseData, null, 2)
  const escapedQuery = searchQuery.value
    .replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    .replace(/"/g, '\\"')
  const regex = new RegExp(escapedQuery, 'gi')
  const matches = [...json.matchAll(regex)]
  
  return {
    count: matches.length,
    matches: matches.map(m => m.index)
  }
})

function syntaxHighlight(json: string): string {
  if (!json) return ''
  json = json
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
  
  let highlighted = json.replace(/("(\\u[a-zA-Z0-9]{4}|\\[^u]|[^\\"])*"(\s*:)?|\b(true|false|null)\b|-?\d+(?:\.\d*)?(?:[eE][+\-]?\d+)?)/g, match => {
    let style = ''
    if (/^".*":$/.test(match)) {
      // Key
      style = 'color: #b0bec5;'
    } else if (/^".*"$/.test(match)) {
      // String value
      style = 'color: #f5faff;'
    } else if (/true|false/.test(match)) {
      style = 'color: #f5faff;'
    } else if (/null/.test(match)) {
      style = 'color: #f5faff; font-style: italic;'
    } else {
      // Number
      style = 'color: #f5faff;'
    }
    return `<span style="${style}">${match}</span>`
  })

  // Highlight search matches if search is active
  if (searchQuery.value && searchQuery.value.length >= 2) {
    // Escape special regex characters but preserve whitespace and quotes
    const escapedQuery = searchQuery.value
      .replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
      .replace(/"/g, '\\"')
    const regex = new RegExp(escapedQuery, 'gi')
    highlighted = highlighted.replace(regex, match => `<span style="background-color: #42b983; color: #1b222c;">${match}</span>`)
  }

  return highlighted
}

const formattedResponse = computed(() => {
  if (!props.responseData) return ''
  try {
    const json = JSON.stringify(JSON.parse(props.responseData), null, 2)
    return syntaxHighlight(json)
  } catch {
    return String(props.responseData)
  }
})

const formattedSize = computed(() => {
  if (!props.responseSize) return '0 KB'
  const kb = props.responseSize / 1024
  return `${kb.toFixed(2)} KB`
})

const disableNativeAutofill = () => {
  // Implementation of disableNativeAutofill function
}

function clearSearch() {
  searchQuery.value = ''
  currentMatchIndex.value = -1
}

function cycleNextMatch() {
  if (!searchResults.value.count) return
  currentMatchIndex.value = (currentMatchIndex.value + 1) % searchResults.value.count
  const matchIndex = searchResults.value.matches[currentMatchIndex.value]
  if (matchIndex !== undefined) {
    const element = document.querySelector('.response-content')
    if (element) {
      const highlightedElements = element.querySelectorAll('span[style*="background-color: #42b983"]')
      if (highlightedElements[currentMatchIndex.value]) {
        const container = document.querySelector('.content-container')
        if (container) {
          const targetElement = highlightedElements[currentMatchIndex.value]
          const containerRect = container.getBoundingClientRect()
          const targetRect = targetElement.getBoundingClientRect()
          const scrollTop = targetRect.top - containerRect.top - (containerRect.height / 2) + container.scrollTop
          container.scrollTo({
            top: scrollTop,
            behavior: 'smooth'
          })
        }
      }
    }
  }
}

function handleKeyDown(event: KeyboardEvent) {
  if (event.key === 'Enter') {
    event.preventDefault()
    cycleNextMatch()
  }
}
</script>
<template>
  <div style="width: 100%; height: 100%; display: flex; flex-direction: column; position: relative;">
    <!-- Fixed header -->
    <div style="height: 64px; min-height: 64px; max-height: 64px; background: #232b36; border-bottom: 1px solid #2c3e50; display: flex; align-items: center; justify-content: space-between; padding: 0 16px; flex-shrink: 0; position: absolute; top: 0; left: 0; right: 0; z-index: 10;">
      <div class="flex items-center h-full">
        <h2 class="font-bold text-white whitespace-nowrap">Response</h2>
      </div>
      <div class="flex items-center h-full gap-2">
        <div class="relative flex items-center">
          <input
            v-model="searchQuery"
            type="text"
            placeholder="Search in response..."
            class="w-48 px-2 h-6 rounded bg-[#232b36] border border-[#2c3e50] text-white focus:outline-none text-[0.75rem] no-autofill"
            :style="{ width: searchQuery ? '200px' : '160px' }"
            autocomplete="off"
            autocorrect="off"
            autocapitalize="off"
            spellcheck="false"
            inputmode="none"
            @focus="disableNativeAutofill"
            @input="disableNativeAutofill"
            @keydown="handleKeyDown"
          />
          <div v-if="searchQuery && searchQuery.length >= 2 && searchResults.count > 0" class="text-[#42b983] text-[0.75rem] ml-2">
            {{ currentMatchIndex + 1 }}/{{ searchResults.count }} matches
          </div>
          <button
            v-if="searchQuery"
            @click="clearSearch"
            class="text-[#b0bec5] hover:text-white focus:outline-none ml-2 text-[0.75rem]"
          >
            ×
          </button>
        </div>
        <div v-if="props.sendLoading" class="flex items-center gap-2 text-[#42b983]">
          <svg class="animate-spin h-4 w-4" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
            <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
          </svg>
          <span class="text-sm">Loading...</span>
        </div>
      </div>
    </div>

    <!-- Scrollable content -->
    <div class="content-container" style="flex: 1 1 0; min-height: 0; overflow: auto; padding: 16px; margin-top: 64px;">
      <div v-if="props.sendError" class="bg-red-900 text-red-200 rounded p-2 mb-2">{{ props.sendError }}</div>
      <div v-if="!props.sendLoading && !props.sendError && props.responseData" class="bg-[#232b36] rounded p-2 font-mono text-xs whitespace-pre-wrap response-content" style="min-height: 120px; color: #b0bec5;">
        <span v-html="formattedResponse"></span>
      </div>
      <div v-else-if="!props.sendLoading && !props.sendError && !props.responseData" class="text-[#b0bec5] mt-2">
        No response yet. Click <span class="font-bold">Send</span> to make a request.
      </div>
    </div>

    <!-- Status bar -->
    <div style="height: 28px; min-height: 28px; max-height: 28px; background: #1b222c; border-top: 1px solid #2c3e50; display: flex; align-items: center; justify-content: flex-end; padding-left: 16px; padding-right: 8px; font-size: 0.8rem; flex-shrink: 0; color: #fff; margin: 0; gap: 8px;">
      <template v-if="!props.sendLoading && !props.sendError && props.responseData">
        <span class="text-[#b0bec5]">Response time: <span class="text-[#42b983]">{{ props.responseTime }}ms</span></span>
        <span class="text-[#b0bec5]">Size: <span class="text-[#42b983]">{{ formattedSize }}</span></span>
      </template>
    </div>
  </div>
</template>

<style>
.no-autofill {
  -webkit-user-modify: read-write-plaintext-only !important;
  -webkit-autofill: off !important;
  -webkit-text-fill-color: inherit !important;
}
</style> 
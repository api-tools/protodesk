<script setup lang="ts">
import { defineProps, computed } from 'vue'

const props = defineProps<{
  responseData: any
  sendLoading: boolean
  sendError?: string
  selectedService?: string
  selectedMethod?: string
}>()

function syntaxHighlight(json: string): string {
  if (!json) return ''
  json = json
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
  return json.replace(/("(\\u[a-zA-Z0-9]{4}|\\[^u]|[^\\"])*"(\s*:)?|\b(true|false|null)\b|-?\d+(?:\.\d*)?(?:[eE][+\-]?\d+)?)/g, match => {
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
</script>
<template>
  <div style="width: 100%; height: 100%;">
    <div class="column-header flex items-center justify-between mb-2">
      <h2 class="font-bold text-white whitespace-nowrap">Response</h2>
    </div>
    <hr class="border-t border-[#2c3e50] mb-3" />
    <div v-if="props.sendLoading" class="bg-blue-900 text-blue-200 rounded p-2 mb-2">Sending request...</div>
    <div v-if="props.sendError" class="bg-red-900 text-red-200 rounded p-2 mb-2">{{ props.sendError }}</div>
    <div v-if="!props.sendLoading && !props.sendError && props.responseData" class="bg-[#232b36] rounded p-2 font-mono text-xs whitespace-pre-wrap" style="min-height: 120px; color: #b0bec5;">
      <span v-html="formattedResponse"></span>
    </div>
    <div v-else-if="!props.sendLoading && !props.sendError && !props.responseData" class="text-[#b0bec5] mt-2">
      No response yet. Click <span class="font-bold">Send</span> to make a request.
    </div>
  </div>
</template> 
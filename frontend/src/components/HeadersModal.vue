<script setup lang="ts">
import { defineProps, defineEmits } from 'vue'

const props = defineProps<{
  show: boolean
  perRequestHeadersJson: string
  perRequestHeadersError?: string
}>()
const emit = defineEmits([
  'update:perRequestHeadersJson',
  'save',
  'reset',
  'close'
])
</script>
<template>
  <div v-if="props.show" class="fixed inset-0 bg-black bg-opacity-40 flex items-center justify-center z-50">
    <div class="bg-[#29323b] text-white rounded-lg shadow-lg p-6 w-full max-w-lg text-[0.8rem] relative">
      <button class="absolute top-2 right-4 text-xl text-gray-400 hover:text-gray-700 font-bold" @click="emit('close')">&times;</button>
      <h3 class="text-lg font-bold mb-4">Edit Per-Request Headers</h3>
      <label class="font-semibold mb-2 block">Array of headers in JSON format</label>
      <textarea
        :value="props.perRequestHeadersJson"
        @input="emit('update:perRequestHeadersJson', ($event.target as HTMLTextAreaElement)?.value || '')"
        class="bg-[#232b36] border border-[#2c3e50] rounded px-2 py-1 text-xs text-white focus:outline-none w-full font-mono"
        style="font-size: 0.75rem; line-height: 1.2; height: 120px; resize: none;"
        autocomplete="off"
        spellcheck="false"
        placeholder='[\n  { "Authorization": "token" }\n]'
      ></textarea>
      <div v-if="props.perRequestHeadersError" class="bg-red-700 text-white mt-2 p-2 rounded">{{ props.perRequestHeadersError }}</div>
      <div class="flex gap-2 mt-4">
        <button class="px-3 py-1 rounded bg-[#42b983] text-white hover:bg-[#369870] text-xs font-bold" @click="emit('save')">Save</button>
        <button class="px-3 py-1 rounded bg-[#374151] text-white hover:bg-[#232b36] text-xs font-bold" @click="emit('reset')">Reset to server's default</button>
        <button class="px-3 py-1 rounded bg-[#374151] text-white hover:bg-[#232b36] text-xs font-bold" @click="emit('close')">Cancel</button>
      </div>
    </div>
  </div>
</template> 
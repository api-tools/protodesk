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
    <div class="bg-white text-[#222] rounded-lg shadow-lg p-6 w-full max-w-lg text-[0.8rem] relative">
      <button class="absolute top-2 right-4 text-xl text-gray-400 hover:text-gray-700 font-bold" @click="emit('close')">&times;</button>
      <h3 class="text-lg font-bold mb-4">Edit Per-Request Headers</h3>
      <label class="font-semibold mb-2 block">Array of headers in JSON format</label>
      <textarea
        :value="props.perRequestHeadersJson"
        @input="emit('update:perRequestHeadersJson', ($event.target as HTMLTextAreaElement)?.value || '')"
        class="w-full px-2 py-1 rounded border border-[#2c3e50] text-[0.8rem] font-mono"
        style="height: 120px; resize: none; font-size: 0.8rem; line-height: 1.2;"
        autocomplete="off"
        spellcheck="false"
        placeholder='[\n  { "Authorization": "token" }\n]'
      ></textarea>
      <div v-if="props.perRequestHeadersError" class="text-red-500 text-xs mt-1">{{ props.perRequestHeadersError }}</div>
      <div class="flex gap-2 mt-4">
        <button class="bg-[#42b983] text-white rounded px-3 py-1 font-bold hover:bg-[#369870] transition" @click="emit('save')">Save</button>
        <button class="bg-gray-200 text-[#222] rounded px-3 py-1 font-bold hover:bg-gray-300 transition" @click="emit('reset')">Reset to server's default</button>
        <button class="bg-gray-200 text-[#222] rounded px-3 py-1 font-bold hover:bg-gray-300 transition" @click="emit('close')">Cancel</button>
      </div>
    </div>
  </div>
</template> 
<script setup lang="ts">
import { defineProps, defineEmits, ref, watch } from 'vue'

const props = defineProps<{
  show: boolean
  previewGrpcurlCommand: string
}>()
const emit = defineEmits(['close', 'update'])

const editedCommand = ref('')
const error = ref('')

watch(() => props.previewGrpcurlCommand, (val) => {
  editedCommand.value = val
  error.value = ''
}, { immediate: true })

function handleUpdate() {
  // Basic syntax check: must start with 'grpcurl' and contain -d '<json>'
  const match = editedCommand.value.match(/-d\s+'([^']+)'/)
  if (!editedCommand.value.trim().startsWith('grpcurl')) {
    error.value = 'Command must start with grpcurl.'
    return
  }
  if (!match) {
    error.value = 'Command must include a -d flag with JSON data.'
    return
  }
  try {
    JSON.parse(match[1])
  } catch (e) {
    error.value = 'Invalid JSON in -d flag.'
    return
  }
  error.value = ''
  emit('update', editedCommand.value)
  emit('close')
}
</script>
<template>
  <div v-if="props.show" class="fixed inset-0 bg-black bg-opacity-40 flex items-center justify-center z-50">
    <div class="bg-[#29323b] text-white rounded-lg shadow-lg p-6 w-full max-w-lg text-[0.8rem] relative">
      <button class="absolute top-2 right-4 text-xl text-gray-400 hover:text-gray-700 font-bold" @click="emit('close')">&times;</button>
      <h3 class="text-lg font-bold mb-4">Request preview</h3>
      <textarea
        v-model="editedCommand"
        class="bg-[#232b36] border border-[#2c3e50] rounded px-2 py-1 text-xs text-white focus:outline-none w-full font-mono"
        style="font-size: 0.75rem; line-height: 1.2; height: 120px; resize: none;"
        autocomplete="off"
        autocorrect="off"
        autocapitalize="off"
        spellcheck="false"
      ></textarea>
      <div v-if="error" class="bg-red-700 text-white mt-2 p-2 rounded">{{ error }}</div>
      <div class="flex justify-end gap-2 mt-4">
        <button class="px-3 py-1 rounded bg-[#374151] text-white hover:bg-[#232b36] text-xs" @click="emit('close')">Cancel</button>
        <button class="px-3 py-1 rounded bg-[#42b983] text-white hover:bg-[#369870] text-xs font-bold" @click="handleUpdate">Update</button>
      </div>
    </div>
  </div>
</template> 
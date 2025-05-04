<script setup lang="ts">
import { defineProps, defineEmits } from 'vue'

const props = defineProps<{
  show: boolean
  previewGrpcurlCommand: string
}>()
const emit = defineEmits(['close'])
</script>
<template>
  <div v-if="props.show" class="fixed inset-0 bg-black bg-opacity-40 flex items-center justify-center z-50">
    <div class="bg-white text-[#222] rounded-lg shadow-lg p-6 w-full max-w-lg text-[0.8rem] relative">
      <button class="absolute top-2 right-4 text-xl text-gray-400 hover:text-gray-700 font-bold" @click="emit('close')">&times;</button>
      <h3 class="text-lg font-bold mb-4">Request preview</h3>
      <textarea
        readonly
        class="bg-gray-100 rounded p-2 text-xs w-full font-mono border border-gray-300"
        style="height: 120px; resize: none; font-size: 0.8rem; line-height: 1.2;"
        :value="props.previewGrpcurlCommand"
      ></textarea>
    </div>
  </div>
</template> 
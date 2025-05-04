<script setup lang="ts">
import { defineProps, computed } from 'vue'

const props = defineProps<{
  sendError: string
  formattedResponse: string
  loading?: boolean
}>()

const parsedJson = computed(() => {
  try {
    return JSON.parse(props.formattedResponse)
  } catch {
    return null
  }
})

function renderJsonTree(data: any, indent = 0): string[] {
  if (Array.isArray(data)) {
    return [
      '[\n',
      ...data.map((item, idx) => [
        ' '.repeat((indent + 1) * 2),
        ...renderJsonTree(item, indent + 1),
        idx < data.length - 1 ? ',\n' : '\n'
      ]).flat(),
      ' '.repeat(indent * 2),
      ']'
    ]
  } else if (data && typeof data === 'object') {
    const keys = Object.keys(data)
    return [
      '{\n',
      ...keys.map((key, idx) => [
        ' '.repeat((indent + 1) * 2),
        `<span style=\"color: #b0bec5\">\"${key}\"</span>: `,
        ...renderJsonTree(data[key], indent + 1),
        idx < keys.length - 1 ? ',\n' : '\n'
      ]).flat(),
      ' '.repeat(indent * 2),
      '}'
    ]
  } else {
    return [`<span style=\"color: #f5faff\">${JSON.stringify(data)}</span>`]
  }
}
</script>
<template>
  <section class="flex flex-col flex-1 h-full bg-[#232b36] p-3 scrollable-column">
    <div class="flex items-center justify-between mb-2 min-h-[40px]">
      <h2 class="font-bold text-white whitespace-nowrap">Response</h2>
    </div>
    <hr class="border-t border-[#2c3e50] mb-3" />
    <div class="flex-1 whitespace-pre-wrap font-mono" style="font-size: 0.7rem; color: #b0bec5;">
      <div v-if="props.sendError" class="bg-red-900 text-red-200 rounded p-2 mb-2">{{ props.sendError }}</div>
      <div v-else-if="props.loading" class="bg-blue-900 text-blue-200 rounded p-2 mb-2">Loading response...</div>
      <template v-else>
        <div v-if="parsedJson" v-html="renderJsonTree(parsedJson).join('')"></div>
        <span v-else-if="props.formattedResponse">{{ props.formattedResponse }}</span>
        <span v-else class="italic">[No response yet]</span>
      </template>
    </div>
  </section>
</template> 
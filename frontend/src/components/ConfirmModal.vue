<template>
  <div v-if="show" class="fixed inset-0 z-50 flex items-center justify-center bg-black bg-opacity-50">
    <div class="bg-[#29323b] text-white rounded-lg shadow-lg p-6 w-full max-w-sm text-[0.8rem]">
      <h3 class="text-lg font-bold mb-2">{{ title }}</h3>
      <div class="mb-6 text-[#b0bec5]">{{ message }}</div>
      <div class="flex gap-2 justify-end">
        <button @click="onCancel" class="bg-[#374151] text-white rounded px-4 py-1 hover:bg-[#232b36] transition">{{ cancelText || 'Cancel' }}</button>
        <button @click="onConfirm" class="bg-[#42b983] text-white rounded px-4 py-1 hover:bg-[#369870] transition">{{ confirmText || 'Confirm' }}</button>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { defineProps } from 'vue'
const props = defineProps<{
  show: boolean
  title: string
  message: string
  confirmText?: string
  cancelText?: string
  onConfirm: () => void
  onCancel: () => void
}>()
</script> 
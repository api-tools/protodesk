<script setup lang="ts">
import { defineProps, defineEmits } from 'vue'

const props = defineProps({
  services: { type: Array, required: true },
  expandedServices: { type: Object, required: true },
  selectedService: { type: String, default: null },
  selectedMethod: { type: String, default: null },
  connectionLoading: { type: Boolean, default: false },
  connectionError: { type: String, default: null },
  reflectionError: { type: String, default: null },
  methodSearch: { type: String, required: true },
})

const emit = defineEmits(['toggleService', 'selectMethod', 'update:methodSearch'])

function handleToggleService(serviceName: string) {
  emit('toggleService', serviceName)
}
function handleSelectMethod(serviceName: string, methodName: string) {
  emit('selectMethod', serviceName, methodName)
}
function updateSearch(e: Event) {
  emit('update:methodSearch', (e.target as HTMLInputElement).value)
}
function clearSearch() {
  emit('update:methodSearch', '')
}
</script>

<template>
  <div style="width: 100%; height: 100%; font-size: 0.9rem;">
    <div class="column-header flex items-center justify-between mb-2" style="min-height:48px;max-height:48px;height:48px;">
      <h2 class="font-bold text-white whitespace-nowrap" style="margin-right: 12px;">Services</h2>
      <div class="relative flex-1 flex items-center" style="max-width: 220px;">
        <input
          :value="props.methodSearch"
          @input="updateSearch"
          type="text"
          placeholder="Search methods..."
          class="bg-[#232b36] border border-[#2c3e50] rounded px-2 py-1 text-xs text-white focus:outline-none w-full pr-6"
          style="min-width: 120px;"
          autocomplete="off"
          autocorrect="off"
          autocapitalize="off"
        />
        <button v-if="props.methodSearch" @click="clearSearch" class="absolute right-1 top-1/2 -translate-y-1/2 text-[#b0bec5] hover:text-white text-xs px-1 py-0.5 rounded focus:outline-none" style="background: none; border: none;">
          &times;
        </button>
      </div>
    </div>
    <hr class="border-t border-[#2c3e50] mb-3" />
    <div v-if="connectionLoading" class="bg-blue-900 text-blue-200 rounded p-2 mb-2">Connecting to server...</div>
    <div v-if="connectionError" class="bg-red-900 text-red-200 rounded p-2 mb-2">{{ connectionError }}</div>
    <div v-if="reflectionError" class="bg-red-900 text-red-200 rounded p-2 mb-2">{{ reflectionError }}</div>
    <div v-if="services.length === 0 && !connectionLoading" class="bg-[#29323b] rounded p-4 text-[#b0bec5] mt-2">
      No proto services found for this server.
    </div>
    <div v-else-if="!connectionLoading" class="mt-2 space-y-2 overflow-y-auto">
      <div v-for="service in services as Array<{ name: string, methods: Array<{ name: string }> }>" :key="service.name" class="">
        <div class="flex items-center select-none">
          <span class="mr-1 cursor-pointer flex items-center" @click.stop="handleToggleService(service.name)">
            <span v-if="expandedServices[service.name]">
              <!-- Down chevron SVG -->
              <svg width="14" height="14" viewBox="0 0 20 20" fill="none"><path d="M6 8l4 5 4-5" stroke="#b0bec5" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>
            </span>
            <span v-else>
              <!-- Right chevron SVG -->
              <svg width="14" height="14" viewBox="0 0 20 20" fill="none"><path d="M7 6l5 4-5 4" stroke="#b0bec5" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>
            </span>
          </span>
          <span class="font-normal text-white cursor-pointer" @click="handleToggleService(service.name)">{{ service.name }}</span>
        </div>
        <transition name="fade">
          <div v-show="expandedServices[service.name]" class="ml-5 mt-1 space-y-1">
            <div v-for="method in service.methods as Array<{ name: string }>" :key="method.name"
                 class="px-2 py-1 rounded cursor-pointer text-[#8a94a0] hover:bg-[#2c3e50] hover:text-white"
                 :class="{ 'bg-[#2c3e50] text-white': selectedService === service.name && selectedMethod === method.name }"
                 @click.stop="handleSelectMethod(service.name, method.name)">
              {{ method.name }}
            </div>
          </div>
        </transition>
      </div>
    </div>
  </div>
</template> 
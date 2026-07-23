<script setup lang="ts">
import {computed, reactive, ref} from 'vue'
import {ChevronDown, ChevronRight, Search} from '@lucide/vue'
import type {GrpcMethod, GrpcService} from '../../types/grpc'

const props = defineProps<{
  services: GrpcService[]
  selectedMethod: GrpcMethod | null
  connected: boolean
  reflectionUnavailable: boolean
  protoSourceError?: string
}>()

defineEmits<{
  selectMethod: [method: GrpcMethod]
}>()

const searchQuery = ref('')
const collapsedServices = reactive<Record<string, boolean>>({})

const normalizedSearch = computed(() => searchQuery.value.trim().toLowerCase())
const filteredServices = computed(() => {
  const query = normalizedSearch.value
  if (!query) return props.services

  return props.services
    .map((service) => ({
      ...service,
      methods: service.methods.filter((method) => methodMatchesSearch(method, query)),
    }))
    .filter((service) => service.methods.length > 0)
})
const filteredMethodCount = computed(() => {
  return filteredServices.value.reduce((count, service) => count + service.methods.length, 0)
})
const totalMethodCount = computed(() => {
  return props.services.reduce((count, service) => count + service.methods.length, 0)
})

function methodType(method: GrpcMethod): string {
  if (method.clientStreaming && method.serverStreaming) return 'Bidi stream'
  if (method.clientStreaming) return 'Client stream'
  if (method.serverStreaming) return 'Server stream'
  return 'Unary'
}

function methodMatchesSearch(method: GrpcMethod, query: string): boolean {
  const searchable = [
    method.serviceName,
    method.methodName,
    method.fullName,
    method.requestType,
    method.responseType,
    methodType(method),
  ].join(' ').toLowerCase()
  return searchable.includes(query)
}

function isServiceCollapsed(serviceName: string): boolean {
  return !normalizedSearch.value && Boolean(collapsedServices[serviceName])
}

function toggleService(serviceName: string) {
  collapsedServices[serviceName] = !collapsedServices[serviceName]
}
</script>

<template>
  <aside class="panel left-panel">
    <div class="panel-header methods-header">
      <h2>Methods</h2>
      <label class="method-search-wrap">
        <Search :size="14" aria-hidden="true" />
        <input v-model="searchQuery" type="search" placeholder="Search methods">
      </label>
    </div>

    <div v-if="!connected" class="empty-state">
      <strong>No server connected.</strong>
      <span>Connect to a gRPC server to discover available services and methods.</span>
    </div>

    <div v-else-if="protoSourceError" class="empty-state">
      <strong>No methods available.</strong>
      <span>The configured proto sources could not be loaded. Check the bottom status and server setup.</span>
    </div>

    <div v-else-if="reflectionUnavailable && services.length === 0" class="empty-state">
      <strong>No methods available.</strong>
      <span>Server reflection is unavailable and no usable proto sources were configured.</span>
    </div>

    <div v-else-if="services.length === 0" class="empty-state">
      <strong>No methods available.</strong>
      <span>No application services were found in reflection or the configured proto sources.</span>
    </div>

    <div v-else-if="filteredServices.length === 0" class="empty-state">
      <strong>No matching methods.</strong>
      <span>Try a different method, service, request, or response type.</span>
    </div>

    <div v-else class="method-tree">
      <section v-for="service in filteredServices" :key="service.name" class="service-group">
        <button class="service-toggle" type="button" @click="toggleService(service.name)">
          <ChevronRight v-if="isServiceCollapsed(service.name)" :size="14" aria-hidden="true" />
          <ChevronDown v-else :size="14" aria-hidden="true" />
          <span>{{ service.name }}</span>
          <small>{{ service.methods.length }}</small>
        </button>
        <div v-if="!isServiceCollapsed(service.name)" class="service-methods">
          <button
            v-for="method in service.methods"
            :key="method.fullName"
            class="method-row"
            :class="{ selected: selectedMethod?.fullName === method.fullName }"
            type="button"
            @click="$emit('selectMethod', method)"
          >
            <span>{{ method.methodName }}</span>
            <small>{{ methodType(method) }}</small>
          </button>
        </div>
      </section>
    </div>

    <footer v-if="connected" class="methods-status-bar">
      <span>{{ services.length }} services</span>
      <span>{{ totalMethodCount }} methods</span>
      <span v-if="normalizedSearch">{{ filteredMethodCount }} matched</span>
    </footer>
  </aside>
</template>

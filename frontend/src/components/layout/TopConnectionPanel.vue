<script setup lang="ts">
import {Boxes, ChevronDown, Plug, PlugZap, Server, Waypoints} from '@lucide/vue'
import type {ConnectionState, ServerProfile} from '../../types/grpc'
import UiButton from '../ui/UiButton.vue'

defineProps<{
  servers: ServerProfile[]
  selectedServerId: string
  connectionState: ConnectionState
}>()

defineEmits<{
  selectServer: [id: string]
  openWorkspace: []
  openCollections: []
  openServers: []
  connect: []
  disconnect: []
}>()
</script>

<template>
  <header class="top-panel">
    <div class="top-panel-primary">
      <UiButton
        v-if="connectionState === 'connected'"
        variant="danger"
        @click="$emit('disconnect')"
      >
        <template #icon><PlugZap :size="16" aria-hidden="true" /></template>
        Disconnect
      </UiButton>
      <UiButton
        v-else
        variant="primary"
        :disabled="connectionState === 'connecting'"
        @click="$emit('connect')"
      >
        <template #icon><Plug :size="16" aria-hidden="true" /></template>
        {{ connectionState === 'connecting' ? 'Connecting' : 'Connect' }}
      </UiButton>

      <label class="servers-select-wrap">
        <select
          class="servers-select"
          :value="selectedServerId"
          :disabled="connectionState === 'connecting'"
          @change="$emit('selectServer', ($event.target as HTMLSelectElement).value)"
        >
          <option value="" disabled>Select server</option>
          <option v-for="server in servers" :key="server.id" :value="server.id">
            {{ server.name }} · {{ server.address }}
          </option>
        </select>
        <ChevronDown :size="15" aria-hidden="true" />
      </label>
    </div>

    <div class="top-panel-actions">
      <UiButton variant="secondary" @click="$emit('openWorkspace')">
        <template #icon><Waypoints :size="16" aria-hidden="true" /></template>
        Workspace
      </UiButton>

      <UiButton variant="secondary" @click="$emit('openCollections')">
        <template #icon><Boxes :size="16" aria-hidden="true" /></template>
        Collections
      </UiButton>

      <UiButton variant="secondary" @click="$emit('openServers')">
        <template #icon><Server :size="16" aria-hidden="true" /></template>
        Servers
      </UiButton>

      <div class="connection-state" :data-state="connectionState">
        {{ connectionState }}
      </div>
    </div>
  </header>
</template>

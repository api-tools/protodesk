<script setup lang="ts">
import {computed} from 'vue'
import {Clipboard, Copy, Save, RotateCcw, Trash2, X} from '@lucide/vue'
import {ClipboardSetText} from '../../../wailsjs/runtime/runtime'
import type {HistoryItem} from '../../types/grpc'
import UiButton from '../ui/UiButton.vue'
import UiIconButton from '../ui/UiIconButton.vue'

const props = defineProps<{
  open: boolean
  items: HistoryItem[]
  selectedItem: HistoryItem | null
  loading: boolean
}>()

const emit = defineEmits<{
  close: []
  select: [id: string]
  loadRequest: [item: HistoryItem]
  saveAsRequest: [item: HistoryItem, collectionId: string, name: string]
  delete: [id: string]
  clear: []
}>()

const metadataCount = computed(() => {
  if (!props.selectedItem) return 0
  return Object.keys(parseJsonObject(props.selectedItem.requestMetadataJson)).length
})

async function copyHistoryResponse() {
  if (!props.selectedItem) return
  await ClipboardSetText(props.selectedItem.responseJson || '{}')
}

function formatTimestamp(value: string): string {
  if (!value) return ''
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return date.toLocaleString()
}

function parseJsonObject(value: string): Record<string, unknown> {
  try {
    const parsed = JSON.parse(value || '{}')
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>
    }
  } catch {
    return {}
  }
  return {}
}
</script>

<template>
  <Teleport to="body">
    <div v-if="open" class="modal-backdrop" role="presentation" @click.self="$emit('close')">
      <section class="modal-panel history-modal" role="dialog" aria-modal="true" aria-labelledby="history-modal-title">
        <header class="modal-header">
          <div>
            <h2 id="history-modal-title">Invocation History</h2>
            <p>Recent request and response snapshots from local unary calls.</p>
          </div>
          <UiIconButton label="Close history" @click="$emit('close')">
            <X :size="16" aria-hidden="true" />
          </UiIconButton>
        </header>

        <div class="history-modal-grid">
          <aside class="history-list">
            <div class="history-list-header">
              <span>{{ loading ? 'Loading history' : `${items.length} calls` }}</span>
              <UiButton variant="ghost" :disabled="items.length === 0" @click="$emit('clear')">
                <template #icon><Trash2 :size="14" aria-hidden="true" /></template>
                Clear
              </UiButton>
            </div>

            <div v-if="items.length === 0" class="history-empty">
              No invocation history yet.
            </div>

            <button
              v-for="item in items"
              :key="item.id"
              class="history-row"
              :class="{ selected: selectedItem?.id === item.id }"
              type="button"
              @click="$emit('select', item.id)"
            >
              <span class="history-row-top">
                <strong :class="{ ok: item.statusCode === 'OK', failed: item.statusCode !== 'OK' }">
                  {{ item.statusCode }}
                </strong>
                <small>{{ item.durationMs }} ms</small>
              </span>
              <span>{{ item.methodName }}</span>
              <small>{{ item.serverName || item.serverAddress }} · {{ formatTimestamp(item.createdAt) }}</small>
            </button>
          </aside>

          <section class="history-preview">
            <div v-if="!selectedItem" class="empty-state">
              <strong>Select a history item.</strong>
            </div>

            <template v-else>
              <div class="history-preview-header">
                <div>
                  <h3>{{ selectedItem.serviceName }}/{{ selectedItem.methodName }}</h3>
                  <span>{{ selectedItem.serverAddress }} · {{ formatTimestamp(selectedItem.createdAt) }}</span>
                </div>
                <strong :class="{ ok: selectedItem.statusCode === 'OK', failed: selectedItem.statusCode !== 'OK' }">
                  {{ selectedItem.statusCode }} · {{ selectedItem.durationMs }} ms
                </strong>
              </div>

              <div class="history-preview-actions">
                <UiButton variant="secondary" @click="$emit('loadRequest', selectedItem)">
                  <template #icon><RotateCcw :size="14" aria-hidden="true" /></template>
                  Load request
                </UiButton>
                <UiButton variant="secondary" @click="$emit('saveAsRequest', selectedItem, '', selectedItem.methodName)">
                  <template #icon><Save :size="14" aria-hidden="true" /></template>
                  Save as request
                </UiButton>
                <UiButton variant="secondary" @click="copyHistoryResponse">
                  <template #icon><Copy :size="14" aria-hidden="true" /></template>
                  Copy response
                </UiButton>
                <UiButton variant="danger" @click="$emit('delete', selectedItem.id)">
                  <template #icon><Trash2 :size="14" aria-hidden="true" /></template>
                  Delete
                </UiButton>
              </div>

              <div class="history-preview-meta">
                <span><Clipboard :size="14" aria-hidden="true" /> {{ metadataCount }} metadata entries</span>
                <span>{{ selectedItem.fullMethod }}</span>
              </div>

              <div class="history-preview-json-grid">
                <section>
                  <h4>Request</h4>
                  <pre>{{ selectedItem.requestJson }}</pre>
                </section>
                <section>
                  <h4>{{ selectedItem.error ? 'Error' : 'Response' }}</h4>
                  <p v-if="selectedItem.error" class="history-error">{{ selectedItem.error }}</p>
                  <pre>{{ selectedItem.responseJson }}</pre>
                </section>
              </div>
            </template>
          </section>
        </div>
      </section>
    </div>
  </Teleport>
</template>

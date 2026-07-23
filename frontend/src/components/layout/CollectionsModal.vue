<script setup lang="ts">
import {computed, ref, watch} from 'vue'
import {FolderPlus, RotateCcw, Save, Trash2, X} from '@lucide/vue'
import type {Collection, CollectionRequest} from '../../types/grpc'
import UiButton from '../ui/UiButton.vue'
import UiIconButton from '../ui/UiIconButton.vue'

const props = defineProps<{
  open: boolean
  collections: Collection[]
  selectedCollection: Collection | null
  selectedRequest: CollectionRequest | null
  loading: boolean
  canSaveCurrent: boolean
  defaultRequestName: string
}>()

const emit = defineEmits<{
  close: []
  load: [request: CollectionRequest]
  selectCollection: [id: string]
  selectRequest: [id: string]
  createCollection: [name: string, description: string]
  deleteCollection: [id: string]
  saveCurrent: [collectionId: string, name: string]
  deleteRequest: [id: string]
}>()

const newCollectionName = ref('Personal')
const saveRequestName = ref('')

const selectedRequests = computed(() => props.selectedCollection?.requests ?? [])

watch(
  () => [props.open, props.defaultRequestName] as const,
  () => {
    if (props.open) {
      saveRequestName.value = props.defaultRequestName
    }
  },
  {immediate: true},
)

function createCollection() {
  emit('createCollection', newCollectionName.value.trim() || 'Personal', '')
  newCollectionName.value = 'Personal'
}

function saveCurrent() {
  emit('saveCurrent', props.selectedCollection?.id ?? '', saveRequestName.value.trim() || props.defaultRequestName || 'Saved request')
}
</script>

<template>
  <Teleport to="body">
    <div v-if="open" class="modal-backdrop" role="presentation" @click.self="$emit('close')">
      <section class="modal-panel collections-modal" role="dialog" aria-modal="true" aria-labelledby="collections-modal-title">
        <header class="modal-header">
          <div>
            <h2 id="collections-modal-title">Collections</h2>
            <p>Save reusable request templates and load them into the request panel.</p>
          </div>
          <UiIconButton label="Close collections" @click="$emit('close')">
            <X :size="16" aria-hidden="true" />
          </UiIconButton>
        </header>

        <div class="collections-modal-grid">
          <aside class="collection-list">
            <div class="collection-create-row">
              <input v-model="newCollectionName" type="text" aria-label="New collection name" placeholder="Personal">
              <UiIconButton label="Create collection" @click="createCollection">
                <FolderPlus :size="15" aria-hidden="true" />
              </UiIconButton>
            </div>

            <div v-if="collections.length === 0" class="history-empty">
              No collections yet.
            </div>

            <button
              v-for="collection in collections"
              :key="collection.id"
              class="history-row"
              :class="{ selected: selectedCollection?.id === collection.id }"
              type="button"
              @click="$emit('selectCollection', collection.id)"
            >
              <span class="history-row-top">
                <strong>{{ collection.name }}</strong>
                <small>{{ collection.requests.length }}</small>
              </span>
              <small>{{ collection.description || 'Saved requests' }}</small>
            </button>
          </aside>

          <section class="collection-preview">
            <div class="collection-actions">
              <input v-model="saveRequestName" type="text" placeholder="Request name" aria-label="Saved request name">
              <UiButton variant="secondary" :disabled="!canSaveCurrent" @click="saveCurrent">
                <template #icon><Save :size="14" aria-hidden="true" /></template>
                Save current request
              </UiButton>
              <UiButton v-if="selectedCollection" variant="danger" @click="$emit('deleteCollection', selectedCollection.id)">
                <template #icon><Trash2 :size="14" aria-hidden="true" /></template>
                Delete collection
              </UiButton>
            </div>

            <div v-if="!selectedCollection" class="empty-state">
              <strong>Select or create a collection.</strong>
            </div>

            <template v-else>
              <div class="collection-request-list">
                <button
                  v-for="request in selectedRequests"
                  :key="request.id"
                  class="collection-request-row"
                  :class="{ selected: selectedRequest?.id === request.id }"
                  type="button"
                  @click="$emit('selectRequest', request.id)"
                >
                  <strong>{{ request.name }}</strong>
                  <span>{{ request.serviceName }}/{{ request.methodName }}</span>
                </button>
                <div v-if="selectedRequests.length === 0" class="history-empty">No saved requests.</div>
              </div>

              <section v-if="selectedRequest" class="collection-request-preview">
                <div class="history-preview-header">
                  <div>
                    <h3>{{ selectedRequest.name }}</h3>
                    <span>{{ selectedRequest.serverAddress }} · {{ selectedRequest.fullMethod }}</span>
                  </div>
                </div>
                <div class="history-preview-actions">
                  <UiButton variant="secondary" @click="$emit('load', selectedRequest)">
                    <template #icon><RotateCcw :size="14" aria-hidden="true" /></template>
                    Load request
                  </UiButton>
                  <UiButton variant="danger" @click="$emit('deleteRequest', selectedRequest.id)">
                    <template #icon><Trash2 :size="14" aria-hidden="true" /></template>
                    Delete request
                  </UiButton>
                </div>
                <pre>{{ selectedRequest.requestJson }}</pre>
              </section>
            </template>
          </section>
        </div>
      </section>
    </div>
  </Teleport>
</template>

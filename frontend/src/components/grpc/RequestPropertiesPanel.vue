<script setup lang="ts">
import {Braces, Play, X} from '@lucide/vue'
import {ref} from 'vue'
import type {GrpcField, GrpcMethod} from '../../types/grpc'
import UiButton from '../ui/UiButton.vue'
import UiIconButton from '../ui/UiIconButton.vue'
import RequestFieldEditor from './RequestFieldEditor.vue'

const props = defineProps<{
  selectedMethod: GrpcMethod | null
  bodyJson: string
  validationError?: string
  canInvoke: boolean
  isInvoking: boolean
}>()

const emit = defineEmits<{
  'update:bodyJson': [value: string]
  invoke: []
}>()

const bodyModalOpen = ref(false)

function fieldValue(field: GrpcField): unknown {
  return parseBodyJson()[field.jsonName || field.name]
}

function updateField(field: GrpcField, value: unknown) {
  const nextBody = parseBodyJson()
  const fieldName = field.jsonName || field.name
  if (value === '' || value === undefined || value === null) {
    delete nextBody[fieldName]
  } else {
    nextBody[fieldName] = value
  }
  emitBody(nextBody)
}

function parseBodyJson(): Record<string, unknown> {
  try {
    const parsed = JSON.parse(props.bodyJson || '{}')
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return {...parsed}
    }
  } catch {
    return {}
  }
  return {}
}

function emitBody(body: Record<string, unknown>) {
  emit('update:bodyJson', JSON.stringify(body, null, 2))
}

function isTimestampField(field: GrpcField): boolean {
  return field.messageType === 'google.protobuf.Timestamp' || field.messageType?.endsWith('.Timestamp') === true
}

function fieldHint(field: GrpcField): string {
  if (isTimestampField(field)) return 'timestamp'
  if (field.map) return 'map JSON object'
  if (field.repeated) return `${field.messageType || field.type} array`
  if (field.messageType) return field.messageType
  return field.type
}
</script>

<template>
  <main class="panel middle-panel">
    <div class="panel-header">
      <h2>Request</h2>
      <UiButton class="request-invoke-button" variant="primary" :disabled="!canInvoke" @click="$emit('invoke')">
        <template #icon><Play :size="15" aria-hidden="true" /></template>
        {{ isInvoking ? 'Invoking...' : 'Invoke' }}
      </UiButton>
    </div>

    <div v-if="!selectedMethod" class="empty-state">
      <strong>Select a method from the left panel to configure a request.</strong>
    </div>

    <div v-else class="request-stack">
      <section class="section-block">
        <div class="section-title">
          <h3>Fields</h3>
          <span>{{ selectedMethod.requestFields.length }} fields</span>
        </div>
        <div v-if="selectedMethod.requestFields.length === 0" class="field-empty">
          No request fields.
        </div>
        <div v-else class="request-field-list">
          <div v-for="field in selectedMethod.requestFields" :key="field.name" class="request-field-row">
            <span class="request-field-label">
              <strong>{{ field.name }}</strong>
              <small>{{ fieldHint(field) }}</small>
            </span>
            <RequestFieldEditor
              :field="field"
              :value="fieldValue(field)"
              :message-types="selectedMethod.messageTypes"
              @update:value="updateField(field, $event)"
            />
          </div>
        </div>
      </section>
    </div>

    <footer v-if="selectedMethod" class="request-status-bar">
      <span>{{ selectedMethod.requestFields.length }} fields</span>
      <span v-if="validationError" class="request-status-error">{{ validationError }}</span>
      <button class="request-body-button" type="button" aria-label="Open request body JSON" @click="bodyModalOpen = true">
        <Braces :size="15" aria-hidden="true" />
      </button>
    </footer>

    <Teleport to="body">
      <div v-if="bodyModalOpen" class="modal-backdrop" role="presentation" @click.self="bodyModalOpen = false">
        <section class="request-body-modal modal-panel" role="dialog" aria-modal="true" aria-labelledby="request-body-title">
          <header class="modal-header">
            <div>
              <h2 id="request-body-title">Request Body</h2>
              <p>Raw JSON payload generated from the field form.</p>
            </div>
            <UiIconButton label="Close request body" @click="bodyModalOpen = false">
              <X :size="16" aria-hidden="true" />
            </UiIconButton>
          </header>
          <div class="request-body-modal-content">
            <textarea
              class="json-editor request-body-modal-editor"
              :value="bodyJson"
              spellcheck="false"
              @input="$emit('update:bodyJson', ($event.target as HTMLTextAreaElement).value)"
            ></textarea>
            <p v-if="validationError" class="validation-error">{{ validationError }}</p>
          </div>
        </section>
      </div>
    </Teleport>
  </main>
</template>

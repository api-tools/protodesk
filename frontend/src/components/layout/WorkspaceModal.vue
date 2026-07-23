<script setup lang="ts">
import {Download, Upload, X} from '@lucide/vue'
import type {WorkspaceTransferResult} from '../../types/grpc'
import UiButton from '../ui/UiButton.vue'
import UiIconButton from '../ui/UiIconButton.vue'

defineProps<{
  open: boolean
  loading: boolean
  result: WorkspaceTransferResult | null
}>()

defineEmits<{
  close: []
  exportWorkspace: []
  importWorkspace: []
}>()
</script>

<template>
  <Teleport to="body">
    <div v-if="open" class="modal-backdrop" role="presentation" @click.self="$emit('close')">
      <section class="modal-panel workspace-modal" role="dialog" aria-modal="true" aria-labelledby="workspace-modal-title">
        <header class="modal-header">
          <div>
            <h2 id="workspace-modal-title">Workspace</h2>
            <p>Import or export local servers, proto references, collections, and saved request examples.</p>
          </div>
          <UiIconButton label="Close workspace" @click="$emit('close')">
            <X :size="16" aria-hidden="true" />
          </UiIconButton>
        </header>

        <div class="workspace-modal-content">
          <section class="workspace-transfer-actions">
            <UiButton variant="secondary" :disabled="loading" @click="$emit('exportWorkspace')">
              <template #icon><Download :size="15" aria-hidden="true" /></template>
              Export workspace
            </UiButton>
            <UiButton variant="secondary" :disabled="loading" @click="$emit('importWorkspace')">
              <template #icon><Upload :size="15" aria-hidden="true" /></template>
              Import workspace
            </UiButton>
          </section>

          <section class="workspace-transfer-summary">
            <div v-if="loading" class="history-empty">Working...</div>
            <div v-else-if="!result" class="history-empty">No workspace transfer yet.</div>
            <dl v-else>
              <div>
                <dt>Servers</dt>
                <dd>{{ result.serverCount }}</dd>
              </div>
              <div>
                <dt>Collections</dt>
                <dd>{{ result.collectionCount }}</dd>
              </div>
              <div>
                <dt>Saved requests</dt>
                <dd>{{ result.savedRequestCount }}</dd>
              </div>
              <div v-if="result.path">
                <dt>File</dt>
                <dd :title="result.path">{{ result.path }}</dd>
              </div>
              <div v-if="result.skipped">
                <dt>Status</dt>
                <dd>Cancelled</dd>
              </div>
            </dl>
          </section>
        </div>
      </section>
    </div>
  </Teleport>
</template>

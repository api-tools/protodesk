<script setup lang="ts">
import {computed, onMounted, ref} from 'vue'
import TopConnectionPanel from './TopConnectionPanel.vue'
import BottomStatusPanel from './BottomStatusPanel.vue'
import CollectionsModal from './CollectionsModal.vue'
import HistoryModal from './HistoryModal.vue'
import ServersModal from './ServersModal.vue'
import WorkspaceModal from './WorkspaceModal.vue'
import MethodsPanel from '../grpc/MethodsPanel.vue'
import RequestPropertiesPanel from '../grpc/RequestPropertiesPanel.vue'
import ResponsePanel from '../grpc/ResponsePanel.vue'
import {useGrpcClientStore} from '../../stores/grpcClientStore'

const store = useGrpcClientStore()
const serversModalOpen = ref(false)
const workspaceRef = ref<HTMLElement | null>(null)
const columnWidths = ref<[number, number, number] | null>(null)
const minColumnWidth = 240

const workspaceColumns = computed(() => {
  if (!columnWidths.value) {
    return 'minmax(240px, 1fr) 4px minmax(240px, 1fr) 4px minmax(240px, 1fr)'
  }
  const [left, middle, right] = columnWidths.value
  return `${left}px 4px ${middle}px 4px ${right}px`
})

onMounted(() => {
  void store.loadServerProfiles()
})

function startResize(splitterIndex: 0 | 1, event: PointerEvent) {
  const workspace = workspaceRef.value
  if (!workspace) return

  // Prevent the drag gesture from becoming a text-selection gesture when the
  // pointer crosses content in either adjacent column.
  event.preventDefault()
  const rect = workspace.getBoundingClientRect()
  const currentWidths = columnWidths.value ?? getEqualColumnWidths(rect.width)
  const startX = event.clientX
  const startWidths: [number, number, number] = [...currentWidths]

  columnWidths.value = startWidths
  document.body.classList.add('is-resizing-columns')
  ;(event.currentTarget as HTMLElement).setPointerCapture(event.pointerId)

  function onPointerMove(moveEvent: PointerEvent) {
    moveEvent.preventDefault()
    const delta = moveEvent.clientX - startX
    const next: [number, number, number] = [...startWidths]

    if (splitterIndex === 0) {
      const available = startWidths[0] + startWidths[1]
      next[0] = clamp(startWidths[0] + delta, minColumnWidth, available - minColumnWidth)
      next[1] = available - next[0]
    } else {
      const available = startWidths[1] + startWidths[2]
      next[1] = clamp(startWidths[1] + delta, minColumnWidth, available - minColumnWidth)
      next[2] = available - next[1]
    }

    columnWidths.value = next
  }

  function onPointerUp() {
    document.body.classList.remove('is-resizing-columns')
    window.removeEventListener('pointermove', onPointerMove)
    window.removeEventListener('pointerup', onPointerUp)
    window.removeEventListener('pointercancel', onPointerUp)
  }

  window.addEventListener('pointermove', onPointerMove)
  window.addEventListener('pointerup', onPointerUp)
  window.addEventListener('pointercancel', onPointerUp)
}

function getEqualColumnWidths(workspaceWidth: number): [number, number, number] {
  const usableWidth = Math.max(workspaceWidth - 8, minColumnWidth * 3)
  const width = Math.floor(usableWidth / 3)
  return [width, width, usableWidth - width * 2]
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(Math.max(value, min), max)
}
</script>

<template>
  <div class="app-shell">
    <TopConnectionPanel
      :servers="store.serverProfiles"
      :selected-server-id="store.selectedServerId"
      :connection-state="store.connection.state"
      @select-server="store.selectServerProfile"
      @open-workspace="store.openWorkspaceModal"
      @open-collections="store.openCollectionsModal"
      @open-servers="serversModalOpen = true"
      @connect="store.connect"
      @disconnect="store.disconnect"
    />
    <ServersModal
      :open="serversModalOpen"
      :servers="store.serverProfiles"
      :selected-server-id="store.selectedServerId"
      @close="serversModalOpen = false"
      @select-server="store.selectServerProfile"
      @create-server="store.createServerProfile"
      @update-server="store.updateServerProfile"
      @delete-server="store.deleteServerProfile"
    />
    <WorkspaceModal
      :open="store.workspaceModalOpen"
      :loading="store.workspaceTransferLoading"
      :result="store.workspaceTransferResult"
      @close="store.closeWorkspaceModal"
      @export-workspace="store.exportWorkspace"
      @import-workspace="store.importWorkspace"
    />
    <CollectionsModal
      :open="store.collectionsModalOpen"
      :collections="store.collections"
      :selected-collection="store.selectedCollection"
      :selected-request="store.selectedCollectionRequest"
      :loading="store.collectionsLoading"
      :can-save-current="Boolean(store.selectedMethod)"
      :default-request-name="store.selectedMethod?.methodName ?? ''"
      @close="store.closeCollectionsModal"
      @load="store.loadCollectionRequest"
      @select-collection="store.selectCollection"
      @select-request="store.selectCollectionRequest"
      @create-collection="store.createCollection"
      @delete-collection="store.deleteCollection"
      @save-current="store.saveCurrentRequestToCollection"
      @delete-request="store.deleteCollectionRequest"
    />
    <HistoryModal
      :open="store.historyModalOpen"
      :items="store.historyItems"
      :selected-item="store.selectedHistoryItem"
      :loading="store.historyLoading"
      @close="store.closeHistoryModal"
      @select="store.selectHistoryItem"
      @load-request="store.loadHistoryRequest"
      @save-as-request="store.saveHistoryItemToCollection"
      @delete="store.deleteHistoryItem"
      @clear="store.clearHistory"
    />
    <div ref="workspaceRef" class="workspace-grid" :style="{ gridTemplateColumns: workspaceColumns }">
      <MethodsPanel
        :services="store.services"
        :selected-method="store.selectedMethod"
        :connected="store.connection.state === 'connected'"
        :reflection-unavailable="Boolean(store.connection.reflectionUnavailable)"
        :proto-source-error="store.connection.protoSourceError"
        @select-method="store.selectMethod"
      />
      <div
        class="column-resizer"
        role="separator"
        aria-label="Resize methods and request columns"
        aria-orientation="vertical"
        tabindex="0"
        @pointerdown="startResize(0, $event)"
      ></div>
      <RequestPropertiesPanel
        :selected-method="store.selectedMethod"
        :body-json="store.request.bodyJson"
        :validation-error="store.request.validationError"
        :can-invoke="store.canInvoke"
        :is-invoking="store.isInvoking"
        @update:body-json="store.setRequestBody"
        @invoke="store.invoke"
      />
      <div
        class="column-resizer"
        role="separator"
        aria-label="Resize request and response columns"
        aria-orientation="vertical"
        tabindex="0"
        @pointerdown="startResize(1, $event)"
      ></div>
      <ResponsePanel
        :response="store.response"
        :is-invoking="store.isInvoking"
        @open-history="store.openHistoryModal"
      />
    </div>
    <BottomStatusPanel :status="store.status" />
  </div>
</template>

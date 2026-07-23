<script setup lang="ts">
import {computed, reactive, watch} from 'vue'
import {FilePlus, FolderOpen, Plus, Save, Trash2, X} from '@lucide/vue'
import {PickProtoFiles, PickProtoFolder, ValidateProtoSources} from '../../../wailsjs/go/main/App'
import type {ServerProfile} from '../../types/grpc'
import UiButton from '../ui/UiButton.vue'
import UiIconButton from '../ui/UiIconButton.vue'

const props = defineProps<{
  open: boolean
  servers: ServerProfile[]
  selectedServerId: string
}>()

const emit = defineEmits<{
  close: []
  selectServer: [id: string]
  createServer: [profile: Omit<ServerProfile, 'id' | 'workspaceId'>]
  updateServer: [id: string, patch: Partial<Omit<ServerProfile, 'id' | 'workspaceId'>>]
  deleteServer: [id: string]
}>()

const draft = reactive({
  id: '',
  name: '',
  address: '',
  plainText: true,
  reflectionEnabled: true,
  protoFiles: [] as string[],
  protoFolders: [] as string[],
  protoValidationState: 'idle' as 'idle' | 'validating' | 'valid' | 'invalid',
  protoValidationMessage: '',
  protoValidationErrors: [] as string[],
  metadataJson: '{}',
  metadataError: '',
})

const selectedServer = computed(() => props.servers.find((server) => server.id === draft.id) ?? null)
const isEditing = computed(() => Boolean(selectedServer.value))

watch(
  () => [props.open, props.selectedServerId, props.servers.length] as const,
  () => {
    if (!props.open) return
    const server = props.servers.find((item) => item.id === props.selectedServerId) ?? props.servers[0]
    if (server) {
      setDraft(server)
    } else {
      clearDraft()
    }
  },
  {immediate: true},
)

function setDraft(server: ServerProfile) {
  draft.id = server.id
  draft.name = server.name
  draft.address = server.address
  draft.plainText = !server.tlsEnabled
  draft.reflectionEnabled = server.reflectionEnabled
  draft.protoFiles = [...server.protoFiles]
  draft.protoFolders = [...server.protoFolders]
  clearProtoValidation()
  draft.metadataJson = server.metadataJson
  draft.metadataError = ''
}

function clearDraft() {
  draft.id = ''
  draft.name = ''
  draft.address = ''
  draft.plainText = true
  draft.reflectionEnabled = true
  draft.protoFiles = []
  draft.protoFolders = []
  clearProtoValidation()
  draft.metadataJson = '{}'
  draft.metadataError = ''
}

async function saveServer() {
  const metadataError = validateMetadataJson(draft.metadataJson)
  if (metadataError) {
    draft.metadataError = metadataError
    return
  }
  draft.metadataError = ''

  const protoSourcesValid = await validateDraftProtoSources()
  if (!protoSourcesValid) return

  const profile = {
    name: draft.name.trim() || draft.address.trim() || 'Untitled server',
    address: draft.address.trim(),
    tlsEnabled: !draft.plainText,
    reflectionEnabled: draft.reflectionEnabled,
    protoFiles: [...draft.protoFiles],
    protoFolders: [...draft.protoFolders],
    metadataJson: draft.metadataJson.trim() || '{}',
  }
  if (isEditing.value) {
    emit('updateServer', draft.id, profile)
  } else {
    emit('createServer', profile)
  }
  emit('close')
}

async function addProtoFiles() {
  const result = await PickProtoFiles()
  draft.protoFiles = uniquePaths([...draft.protoFiles, ...(result.paths ?? [])])
  await validateDraftProtoSources()
}

async function importProtoFolder() {
  const result = await PickProtoFolder()
  draft.protoFiles = uniquePaths([...draft.protoFiles, ...(result.protoFiles ?? [])])
  await validateDraftProtoSources()
}

async function addProtoFolder() {
  const result = await PickProtoFolder()
  if (result.folder) {
    draft.protoFolders = uniquePaths([...draft.protoFolders, result.folder])
    await validateDraftProtoSources()
  }
}

async function validateDraftProtoSources(): Promise<boolean> {
  clearProtoValidation()
  if (draft.protoFiles.length === 0 && draft.protoFolders.length === 0) {
    return true
  }

  draft.protoValidationState = 'validating'
  try {
    const result = await ValidateProtoSources({
      protoFiles: draft.protoFiles,
      protoFolders: draft.protoFolders,
    })
    if (result.valid) {
      draft.protoValidationState = 'valid'
      draft.protoValidationMessage = `${result.fileCount} proto file${result.fileCount === 1 ? '' : 's'} validated`
      draft.protoValidationErrors = []
      return true
    }
    draft.protoValidationState = 'invalid'
    draft.protoValidationMessage = 'Proto sources need attention'
    draft.protoValidationErrors = result.errors ?? ['Proto validation failed.']
    return false
  } catch (error) {
    draft.protoValidationState = 'invalid'
    draft.protoValidationMessage = 'Proto validation failed'
    draft.protoValidationErrors = [error instanceof Error ? error.message : String(error)]
    return false
  }
}

function clearProtoValidation() {
  draft.protoValidationState = 'idle'
  draft.protoValidationMessage = ''
  draft.protoValidationErrors = []
}

function removeProtoFile(index: number) {
  draft.protoFiles.splice(index, 1)
  clearProtoValidation()
}

function removeProtoFolder(index: number) {
  draft.protoFolders.splice(index, 1)
  clearProtoValidation()
}

function validateMetadataJson(value: string): string {
  const trimmed = value.trim()
  if (!trimmed) return ''
  try {
    const parsed = JSON.parse(trimmed)
    if (!parsed || Array.isArray(parsed) || typeof parsed !== 'object') {
      return 'Metadata must be a JSON object.'
    }
    const invalidEntry = Object.entries(parsed).find(([, metadataValue]) => typeof metadataValue !== 'string')
    if (invalidEntry) {
      return `Metadata value for "${invalidEntry[0]}" must be a string.`
    }
    return ''
  } catch (error) {
    return error instanceof Error ? error.message : 'Invalid metadata JSON.'
  }
}

function uniquePaths(paths: string[]): string[] {
  return [...new Set(paths.map((path) => path.trim()).filter(Boolean))].sort((left, right) => {
    return left.localeCompare(right)
  })
}
</script>

<template>
  <Teleport to="body">
    <div v-if="open" class="modal-backdrop" role="presentation" @click.self="$emit('close')">
      <section class="modal-panel" role="dialog" aria-modal="true" aria-labelledby="servers-modal-title">
        <header class="modal-header">
          <div>
            <h2 id="servers-modal-title">Server Setup</h2>
            <p>Manage server profiles used by the top toolbar.</p>
          </div>
          <UiIconButton label="Close server setup" @click="$emit('close')">
            <X :size="16" aria-hidden="true" />
          </UiIconButton>
        </header>

        <div class="servers-modal-grid">
          <aside class="server-list">
            <button
              v-for="server in servers"
              :key="server.id"
              class="server-list-row"
              :class="{ selected: draft.id === server.id }"
              type="button"
              @click="setDraft(server); $emit('selectServer', server.id)"
            >
              <strong>{{ server.name }}</strong>
              <span>{{ server.address }}</span>
            </button>
            <button class="server-list-row add-row" type="button" @click="clearDraft">
              <Plus :size="15" aria-hidden="true" />
              <span>New server</span>
            </button>
          </aside>

          <form class="server-form" @submit.prevent="saveServer">
            <label>
              <span>Name</span>
              <input v-model="draft.name" type="text" placeholder="Local gRPC">
            </label>

            <label>
              <span>Address</span>
              <input v-model="draft.address" type="text" placeholder="localhost:50051" required>
            </label>

            <div class="modal-toggle-row">
              <label>
                <input v-model="draft.plainText" type="checkbox">
                <span>Use plain text (no TLS)</span>
              </label>
              <label>
                <input v-model="draft.reflectionEnabled" type="checkbox">
                <span>Reflection</span>
              </label>
            </div>

            <section class="proto-picker-section" aria-labelledby="proto-files-title">
              <div class="proto-picker-header">
                <div>
                  <h3 id="proto-files-title">Proto files</h3>
                  <span>Select individual files, or import every .proto from a folder recursively.</span>
                </div>
                <div class="proto-picker-actions">
                  <UiButton variant="secondary" @click="addProtoFiles">
                    <template #icon><FilePlus :size="15" aria-hidden="true" /></template>
                    Add files
                  </UiButton>
                  <UiButton variant="secondary" @click="importProtoFolder">
                    <template #icon><FolderOpen :size="15" aria-hidden="true" /></template>
                    Import folder
                  </UiButton>
                </div>
              </div>
              <div class="proto-entry-list" :class="{ empty: draft.protoFiles.length === 0 }">
                <div v-if="draft.protoFiles.length === 0" class="proto-empty">No proto files selected.</div>
                <div v-for="(file, index) in draft.protoFiles" :key="file" class="proto-entry-row">
                  <span :title="file">{{ file }}</span>
                  <UiIconButton label="Remove proto file" @click="removeProtoFile(index)">
                    <Trash2 :size="14" aria-hidden="true" />
                  </UiIconButton>
                </div>
              </div>
            </section>

            <section class="proto-picker-section" aria-labelledby="proto-folders-title">
              <div class="proto-picker-header">
                <div>
                  <h3 id="proto-folders-title">Proto folders</h3>
                  <span>Use folders as import roots for resolving proto dependencies.</span>
                </div>
                <div class="proto-picker-actions single">
                  <UiButton variant="secondary" @click="addProtoFolder">
                    <template #icon><FolderOpen :size="15" aria-hidden="true" /></template>
                    Add folder
                  </UiButton>
                </div>
              </div>
              <div class="proto-entry-list" :class="{ empty: draft.protoFolders.length === 0 }">
                <div v-if="draft.protoFolders.length === 0" class="proto-empty">No proto folders selected.</div>
                <div v-for="(folder, index) in draft.protoFolders" :key="folder" class="proto-entry-row">
                  <span :title="folder">{{ folder }}</span>
                  <UiIconButton label="Remove proto folder" @click="removeProtoFolder(index)">
                    <Trash2 :size="14" aria-hidden="true" />
                  </UiIconButton>
                </div>
              </div>
            </section>

            <div
              v-if="draft.protoValidationState !== 'idle'"
              class="proto-validation"
              :class="draft.protoValidationState"
            >
              <strong>{{ draft.protoValidationMessage }}</strong>
              <ul v-if="draft.protoValidationErrors.length > 0">
                <li v-for="error in draft.protoValidationErrors" :key="error">{{ error }}</li>
              </ul>
            </div>

            <label>
              <span>Server metadata JSON</span>
              <textarea
                v-model="draft.metadataJson"
                class="server-textarea code-textarea"
                placeholder="{&#10;  &quot;authorization&quot;: &quot;Bearer {{AUTH_TOKEN}}&quot;&#10;}"
                spellcheck="false"
              ></textarea>
              <span v-if="draft.metadataError" class="field-error">{{ draft.metadataError }}</span>
            </label>

            <footer class="modal-actions">
              <UiButton
                v-if="isEditing"
                variant="danger"
                @click="$emit('deleteServer', draft.id); clearDraft()"
              >
                <template #icon><Trash2 :size="15" aria-hidden="true" /></template>
                Delete
              </UiButton>
              <div class="modal-actions-spacer"></div>
              <UiButton variant="secondary" @click="$emit('close')">Cancel</UiButton>
              <UiButton variant="primary" type="submit">
                <template #icon><Save :size="15" aria-hidden="true" /></template>
                {{ isEditing ? 'Save' : 'Create' }}
              </UiButton>
            </footer>
          </form>
        </div>
      </section>
    </div>
  </Teleport>
</template>

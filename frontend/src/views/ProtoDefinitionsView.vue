<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import { useServerProfileStore } from '@/stores/serverProfile'
import { useRouter } from 'vue-router'
import * as AppAPI from '../../wailsjs/go/app/App'
import { proto, app as appModels } from '../../wailsjs/go/models'

const profileStore = useServerProfileStore()
const router = useRouter()

const profiles = computed(() => profileStore.profiles)
const selectedProfileId = ref<string | null>(null)

const protoDefinitions = ref<proto.ProtoDefinition[]>([])
const loading = ref(false)
const error = ref<string | null>(null)

const showUploadForm = ref(false)
const uploadLoading = ref(false)
const uploadError = ref<string | null>(null)
const uploadSuccess = ref(false)
const uploadForm = ref({
  file: null as File | null,
  description: '',
  version: ''
})

const deletingId = ref<string | null>(null)

const viewModal = ref({ open: false, def: null as proto.ProtoDefinition | null })

const importLoading = ref(false)
const importError = ref<string | null>(null)

function goToAddProfile() {
  router.push({ name: 'home' })
}

function openUploadForm() {
  showUploadForm.value = true
  uploadForm.value = { file: null, description: '', version: '' }
  uploadError.value = null
  uploadSuccess.value = false
}

function closeUploadForm() {
  showUploadForm.value = false
}

async function handleFileChange(e: Event) {
  const files = (e.target as HTMLInputElement).files
  uploadForm.value.file = files && files.length > 0 ? files[0] : null
}

async function submitUpload() {
  if (!selectedProfileId.value || !uploadForm.value.file) {
    uploadError.value = 'Please select a file and profile.'
    return
  }
  uploadLoading.value = true
  uploadError.value = null
  uploadSuccess.value = false
  try {
    const file = uploadForm.value.file
    const content = await file.text()
    const def = new proto.ProtoDefinition({
      id: '', // Let backend assign
      filePath: file.name,
      content,
      imports: [],
      services: [],
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      description: uploadForm.value.description,
      version: uploadForm.value.version,
      serverProfileId: selectedProfileId.value
    })
    await AppAPI.SaveProtoDefinition(def)
    uploadSuccess.value = true
    closeUploadForm()
    // Refresh list
    const defs = await AppAPI.ListProtoDefinitionsByProfile(selectedProfileId.value)
    protoDefinitions.value = defs
  } catch (e: any) {
    uploadError.value = e.message || 'Failed to upload proto definition.'
  } finally {
    uploadLoading.value = false
  }
}

async function deleteProtoDefinition(id: string) {
  if (!selectedProfileId.value) return
  if (!confirm('Are you sure you want to delete this proto definition?')) return
  deletingId.value = id
  try {
    await AppAPI.DeleteProtoDefinition(id)
    // Refresh list
    const defs = await AppAPI.ListProtoDefinitionsByProfile(selectedProfileId.value)
    protoDefinitions.value = defs
  } catch (e: any) {
    alert(e.message || 'Failed to delete proto definition.')
  } finally {
    deletingId.value = null
  }
}

function openViewModal(def: proto.ProtoDefinition) {
  viewModal.value.open = true
  viewModal.value.def = def
}

function closeViewModal() {
  viewModal.value.open = false
  viewModal.value.def = null
}

function downloadProto(def: proto.ProtoDefinition) {
  const blob = new Blob([def.content], { type: 'text/plain' })
  const link = document.createElement('a')
  link.href = URL.createObjectURL(blob)
  link.download = def.filePath
  document.body.appendChild(link)
  link.click()
  document.body.removeChild(link)
  URL.revokeObjectURL(link.href)
}

async function importProtoFolder() {
  if (!selectedProfileId.value) {
    importError.value = 'Please select a server profile.'
    return
  }
  importLoading.value = true
  importError.value = null
  try {
    const files: appModels.ProtoFileImport[] = await AppAPI.ImportProtoFilesFromFolder()
    if (!files || files.length === 0) {
      importLoading.value = false
      return
    }
    for (const file of files) {
      const def = new proto.ProtoDefinition({
        id: '', // Let backend assign
        filePath: file.filePath,
        content: '', // Do not store content
        imports: [],
        services: [],
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
        description: '',
        version: '',
        serverProfileId: selectedProfileId.value
      })
      await AppAPI.SaveProtoDefinition(def)
    }
    // Refresh list
    const defs = await AppAPI.ListProtoDefinitionsByProfile(selectedProfileId.value)
    protoDefinitions.value = defs || []
  } catch (e: any) {
    importError.value = e.message || 'Failed to import proto files.'
  } finally {
    importLoading.value = false
  }
}

watch(selectedProfileId, async (profileId) => {
  protoDefinitions.value = []
  error.value = null
  if (!profileId) return
  loading.value = true
  try {
    const defs = await AppAPI.ListProtoDefinitionsByProfile(profileId)
    protoDefinitions.value = defs || []
  } catch (e: any) {
    error.value = e.message || 'Failed to load proto definitions.'
  } finally {
    loading.value = false
  }
})
</script>

<template>
  <div class="proto-definitions-view">
    <h1>Proto Definitions</h1>
    <div v-if="profiles.length === 0" class="no-profiles">
      <p>No server profiles found. Please add a server profile first.</p>
      <button @click="goToAddProfile">Add Server Profile</button>
    </div>
    <div v-else>
      <label for="profile-select">Select Server Profile:</label>
      <select id="profile-select" v-model="selectedProfileId">
        <option disabled value="">-- Select a profile --</option>
        <option v-for="profile in profiles" :key="profile.id" :value="profile.id">
          {{ profile.name }}
        </option>
      </select>
      <div v-if="selectedProfileId" class="proto-list-section">
        <h2>Proto Definitions for Profile: {{ selectedProfileId }}</h2>
        <button @click="importProtoFolder" class="import-btn" :disabled="importLoading">Import Proto Folder</button>
        <div v-if="importLoading">Importing proto files...</div>
        <div v-if="importError" class="error">{{ importError }}</div>
        <button @click="openUploadForm" class="upload-btn">Add Proto Definition</button>
        <div v-if="showUploadForm" class="upload-form">
          <h3>Upload Proto File</h3>
          <form @submit.prevent="submitUpload">
            <input type="file" accept=".proto" @change="handleFileChange" required />
            <input v-model="uploadForm.description" type="text" placeholder="Description" required />
            <input v-model="uploadForm.version" type="text" placeholder="Version" required />
            <button type="submit" :disabled="uploadLoading">Upload</button>
            <button type="button" @click="closeUploadForm">Cancel</button>
          </form>
          <div v-if="uploadError" class="error">{{ uploadError }}</div>
          <div v-if="uploadLoading">Uploading...</div>
        </div>
        <div v-if="loading">Loading proto definitions...</div>
        <div v-else-if="error" class="error">{{ error }}</div>
        <div v-else-if="protoDefinitions.length === 0">No proto definitions found for this profile.</div>
        <table v-else class="proto-table">
          <thead>
            <tr>
              <th>File Path</th>
              <th>Description</th>
              <th>Version</th>
              <th>Created At</th>
              <th>Updated At</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="def in protoDefinitions" :key="def.id">
              <td>{{ def.filePath }}</td>
              <td>{{ def.description }}</td>
              <td>{{ def.version }}</td>
              <td>{{ new Date(def.createdAt).toLocaleString() }}</td>
              <td>{{ new Date(def.updatedAt).toLocaleString() }}</td>
              <td>
                <button class="view-btn" @click="openViewModal(def)">View</button>
                <button class="download-btn" @click="downloadProto(def)">Download</button>
                <button class="delete-btn" @click="deleteProtoDefinition(def.id)" :disabled="deletingId === def.id">
                  <span v-if="deletingId === def.id">Deleting...</span>
                  <span v-else>Delete</span>
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    <div v-if="viewModal.open" class="modal-overlay" @click.self="closeViewModal">
      <div class="modal-content">
        <h3>View Proto File: {{ viewModal.def?.filePath }}</h3>
        <pre class="proto-content">{{ viewModal.def?.content }}</pre>
        <button @click="closeViewModal">Close</button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.proto-definitions-view {
  padding: 2rem;
}
label {
  margin-right: 0.5rem;
}
select {
  margin-bottom: 1rem;
}
.proto-list-section {
  margin-top: 2rem;
}
.no-profiles {
  margin-top: 2rem;
  color: #b71c1c;
}
button {
  margin-top: 1rem;
  padding: 0.5rem 1rem;
  background-color: #42b983;
  color: white;
  border: none;
  border-radius: 4px;
  cursor: pointer;
}
button:hover {
  background-color: #369870;
}
.proto-table {
  width: 100%;
  border-collapse: collapse;
  margin-top: 1rem;
}
.proto-table th, .proto-table td {
  border: 1px solid #ddd;
  padding: 0.5rem 1rem;
  text-align: left;
}
.proto-table th {
  background-color: #f8f9fa;
}
.error {
  color: #b71c1c;
  margin-top: 1rem;
}
.upload-btn, .import-btn {
  margin-bottom: 1rem;
  background-color: #1976d2;
  color: white;
}
.import-btn:hover {
  background-color: #0d47a1;
}
.upload-btn:hover {
  background-color: #0d47a1;
}
.upload-form {
  margin-bottom: 1rem;
  padding: 1rem;
  background: #f8f9fa;
  border-radius: 4px;
  color: #222;
}
.upload-form input[type="file"] {
  margin-bottom: 0.5rem;
}
.upload-form input[type="text"] {
  margin-bottom: 0.5rem;
  padding: 0.5rem;
  border: 1px solid #ddd;
  border-radius: 4px;
  width: 100%;
}
.upload-form button {
  margin-right: 0.5rem;
  padding: 0.5rem 1rem;
  background-color: #42b983;
  color: white;
  border: none;
  border-radius: 4px;
  cursor: pointer;
}
.upload-form button[type="button"] {
  background-color: #757575;
}
.upload-form button:hover {
  background-color: #369870;
}
.upload-form button[type="button"]:hover {
  background-color: #424242;
}
.delete-btn {
  background-color: #b71c1c;
  color: white;
  border: none;
  border-radius: 4px;
  padding: 0.25rem 0.75rem;
  cursor: pointer;
}
.delete-btn:disabled {
  background-color: #ccc;
  cursor: not-allowed;
}
.delete-btn:hover:not(:disabled) {
  background-color: #7f1d1d;
}
.view-btn {
  background-color: #42b983;
  color: white;
  border: none;
  border-radius: 4px;
  padding: 0.25rem 0.75rem;
  margin-right: 0.5rem;
  cursor: pointer;
}
.view-btn:hover {
  background-color: #369870;
}
.download-btn {
  background-color: #1976d2;
  color: white;
  border: none;
  border-radius: 4px;
  padding: 0.25rem 0.75rem;
  margin-right: 0.5rem;
  cursor: pointer;
}
.download-btn:hover {
  background-color: #0d47a1;
}
.modal-overlay {
  position: fixed;
  top: 0;
  left: 0;
  width: 100vw;
  height: 100vh;
  background: rgba(0,0,0,0.5);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 1000;
}
.modal-content {
  background: #fff;
  color: #222;
  padding: 2rem;
  border-radius: 8px;
  max-width: 700px;
  width: 90vw;
  max-height: 80vh;
  overflow-y: auto;
  box-shadow: 0 2px 16px rgba(0,0,0,0.2);
}
.proto-content {
  background: #f8f9fa;
  color: #222;
  padding: 1rem;
  border-radius: 4px;
  font-family: 'Fira Mono', 'Consolas', 'Menlo', monospace;
  font-size: 0.95rem;
  margin-bottom: 1rem;
  white-space: pre-wrap;
  word-break: break-all;
}
</style> 
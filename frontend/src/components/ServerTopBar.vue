<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import { useServerProfileStore } from '@/stores/serverProfile'
import { ListProtoDefinitionsByProfile } from '@wailsjs/go/app/App'
import ConfirmModal from './ConfirmModal.vue'

declare global {
  interface Window {
    runtime?: any;
    Wails?: any;
  }
}

const profileStore = useServerProfileStore()
const profiles = computed(() => profileStore.profiles)
const activeId = computed(() => profileStore.activeProfile?.id || null)

const showModal = ref(false)
const isEdit = ref(false)
const modalProfile = ref({
  id: '',
  name: '',
  host: '',
  port: 50051,
  tlsEnabled: false,
  certificatePath: ''
})

const selectedProfileId = ref<string | null>(null)

// Watch for changes in active profile
watch(
  () => profileStore.activeProfile,
  (profile) => {
    selectedProfileId.value = profile?.id || null
  },
  { immediate: true }
)

function selectProfile(id: string) {
  profileStore.setActiveProfile(id)
  selectedProfileId.value = id
}

// Proto file management for modal
const protoDefinitions = ref<any[]>([])
async function fetchProtoDefinitions() {
  if (!selectedProfileId.value) {
    protoDefinitions.value = []
    return
  }
  try {
    const defs = await ListProtoDefinitionsByProfile(selectedProfileId.value)
    protoDefinitions.value = defs || []
  } catch (e) {
    protoDefinitions.value = []
  }
}
watch(() => showModal.value && selectedProfileId.value, (val) => {
  if (val) fetchProtoDefinitions()
})

function openAdd() {
  isEdit.value = false
  showModal.value = true
  modalProfile.value = { id: '', name: '', host: '', port: 50051, tlsEnabled: false, certificatePath: '' }
  protoFolders.value = []
}

function openEdit(profile: any) {
  isEdit.value = true
  showModal.value = true
  modalProfile.value = { ...profile }
  protoFolders.value = Array.isArray(profile.protoFolders) ? [...profile.protoFolders] : []
}

async function saveProfile() {
  if (!modalProfile.value.name || !modalProfile.value.host || !modalProfile.value.port) return
  if (isEdit.value) {
    await profileStore.updateProfile(modalProfile.value.id, { ...modalProfile.value, protoFolders: [...protoFolders.value] })
  } else {
    const newId = Date.now().toString();
    await profileStore.addProfile({
      ...modalProfile.value,
      id: newId,
      createdAt: new Date(),
      updatedAt: new Date(),
      protoFolders: [...protoFolders.value]
    })
    selectedProfileId.value = newId;
  }
  showModal.value = false
}

const showConfirm = ref(false)
const confirmMessage = ref('Are you sure you want to delete this server profile? This action cannot be undone.')

function handleDeleteClick() {
  showConfirm.value = true
}
function handleConfirmDelete() {
  showConfirm.value = false
  removeProfile()
}
function handleCancelDelete() {
  showConfirm.value = false
}

async function removeProfile() {
  if (selectedProfileId.value) {
    await profileStore.removeProfile(selectedProfileId.value)
    selectedProfileId.value = null
    profileStore.setActiveProfile(null)
  }
}

// Proto folder management
const protoFolders = ref<string[]>([])
async function addProtoFolder() {
  let folder = null;
  if (window.runtime && typeof window.runtime.OpenDirectoryDialog === 'function') {
    folder = await window.runtime.OpenDirectoryDialog({ title: 'Select a proto folder' });
  }
  if (folder && !protoFolders.value.includes(folder)) {
    protoFolders.value.push(folder);
  }
}
function removeProtoFolder(folder: string) {
  protoFolders.value = protoFolders.value.filter(f => f !== folder)
}

// Debug: log profiles whenever they change
watch(
  () => profileStore.profiles,
  (profiles) => {
    console.log('[DEBUG] profiles changed:', profiles)
  },
  { immediate: true }
)

// Debug: manual reload button
function debugReloadProfiles() {
  profileStore.loadProfiles().then(() => {
    console.log('[DEBUG] profiles after reload:', profileStore.profiles)
  })
}
</script>

<template>
  <nav class="w-full bg-[#222c36] text-white px-4 py-2 flex items-center border-b border-[#2c3e50] sticky top-0 z-10 text-[0.8rem]">
    <div class="flex items-center gap-2 flex-wrap w-full">
      <span class="font-semibold">Server:</span>
      <div class="relative min-w-[160px]">
        <select
          class="appearance-none bg-gray-800 border border-[#2c3e50] rounded px-3 py-1 text-white focus:outline-none w-full pr-8"
          v-model="selectedProfileId"
          @change="selectedProfileId && selectProfile(selectedProfileId)"
        >
          <option disabled value="">-- Select a server --</option>
          <option v-for="profile in profiles" :key="profile.id" :value="profile.id">
            {{ profile.name }}
          </option>
        </select>
        <span class="pointer-events-none absolute right-2 top-1/2 -translate-y-1/2 text-gray-400">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" d="M19 9l-7 7-7-7"/>
          </svg>
        </span>
      </div>
      <button class="ml-2 bg-[#42b983] text-[#222] rounded px-3 py-1 font-bold hover:bg-[#369870] transition" @click="openAdd">＋ Add Server</button>
      <button v-if="selectedProfileId" class="text-[#42b983] underline hover:text-[#369870] px-2" @click="openEdit(profiles.find(p => p.id === selectedProfileId))">Edit</button>
      <button v-if="selectedProfileId" class="text-[#42b983] underline hover:text-[#369870] px-2" @click="handleDeleteClick">Delete</button>
      <!-- Debug: manual reload button (optional, can remove if not needed) -->
    </div>
    <!-- Modal -->
    <div v-if="showModal" class="fixed inset-0 bg-black bg-opacity-40 flex items-center justify-center z-50">
      <div class="bg-white text-[#222] rounded-lg shadow-lg p-6 w-full max-w-md text-[0.8rem]">
        <h3 class="text-lg font-bold mb-4">{{ isEdit ? 'Edit' : 'Add' }} Server Profile</h3>
        <form @submit.prevent="saveProfile" class="flex flex-col gap-3">
          <input v-model="modalProfile.name" type="text" placeholder="Profile Name" required class="border rounded px-3 py-2" />
          <input v-model="modalProfile.host" type="text" placeholder="Host" required class="border rounded px-3 py-2" />
          <input v-model.number="modalProfile.port" type="number" placeholder="Port" min="1" required class="border rounded px-3 py-2" />
          <label class="flex items-center gap-2">
            <input v-model="modalProfile.tlsEnabled" type="checkbox" /> TLS Enabled
          </label>
          <input v-model="modalProfile.certificatePath" type="text" placeholder="Certificate Path (optional)" class="border rounded px-3 py-2" />
          <div class="flex gap-2 mt-2">
            <button type="submit" class="bg-[#42b983] text-[#222] rounded px-4 py-1 font-bold hover:bg-[#369870] transition">Save</button>
            <button type="button" class="bg-gray-400 text-white rounded px-4 py-1 font-bold hover:bg-gray-600 transition" @click="showModal = false">Cancel</button>
          </div>
        </form>
        <div class="mt-6">
          <h4 class="font-semibold mb-2">Proto Folders</h4>
          <div class="flex flex-col gap-2">
            <div v-for="folder in protoFolders" :key="folder" class="flex items-center justify-between bg-[#29323b] text-[#b0bec5] rounded px-3 py-1">
              <span class="truncate">{{ folder }}</span>
              <button class="text-[#b71c1c] underline hover:text-[#7f1d1d] ml-2" @click="removeProtoFolder(folder)">Remove</button>
            </div>
            <button class="bg-[#42b983] text-[#222] rounded px-3 py-1 font-bold hover:bg-[#369870] transition mt-1 self-start" @click="addProtoFolder">＋ Add Proto Folder</button>
          </div>
        </div>
        <div v-if="isEdit" class="mt-6">
          <h4 class="font-semibold mb-2">Proto Files</h4>
          <div v-if="protoDefinitions.length === 0" class="text-gray-500">No proto files for this server.</div>
          <ul v-else class="list-disc pl-5">
            <li v-for="file in protoDefinitions" :key="file.id">{{ file.filePath }}</li>
          </ul>
        </div>
      </div>
    </div>
    <ConfirmModal
      :show="showConfirm"
      title="Delete Server Profile"
      :message="confirmMessage"
      confirmText="Delete"
      cancelText="Cancel"
      :onConfirm="handleConfirmDelete"
      :onCancel="handleCancelDelete"
    />
  </nav>
</template> 
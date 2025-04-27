<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import { useServerProfileStore } from '@/stores/serverProfile'
import { ListProtoDefinitionsByProfile, SelectProtoFolder, ImportProtoFilesFromFolder, ScanAndParseProtoPath, CreateProtoPath } from '@wailsjs/go/app/App'
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
  certificatePath: '',
  useReflection: false
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
  modalProfile.value = { id: '', name: '', host: '', port: 50051, tlsEnabled: false, certificatePath: '', useReflection: false }
  protoFolders.value = []
}

function openEdit(profile: any) {
  isEdit.value = true
  showModal.value = true
  modalProfile.value = { ...profile, useReflection: profile.useReflection ?? false }
  protoFolders.value = Array.isArray(profile.protoFolders) ? [...profile.protoFolders] : []
}

async function saveProfile() {
  if (!modalProfile.value.name || !modalProfile.value.host || !modalProfile.value.port) return;
  let createdProfile;
  if (isEdit.value) {
    await profileStore.updateProfile(modalProfile.value.id, { ...modalProfile.value, protoFolders: [...protoFolders.value], useReflection: modalProfile.value.useReflection });
    createdProfile = { id: modalProfile.value.id };
  } else {
    createdProfile = await profileStore.addProfile({
      ...modalProfile.value,
      id: '',
      createdAt: new Date(),
      updatedAt: new Date(),
      protoFolders: [...protoFolders.value],
      useReflection: modalProfile.value.useReflection
    });
  }
  // After creating/updating the server, save proto paths and definitions
  for (const folder of protoFolders.value) {
    const protoPathId = Math.random().toString(36).substring(2, 12);
    try {
      await CreateProtoPath(protoPathId, createdProfile.id, folder);
    } catch (e) {
      infoModalMessage.value = `Failed to save proto path: ${folder}. Error: ${e}`;
      showInfoModal.value = true;
      continue;
    }
    try {
      await ScanAndParseProtoPath(createdProfile.id, protoPathId, folder);
    } catch (e) {
      infoModalMessage.value = `Failed to parse proto files in: ${folder}. Error: ${e}`;
      showInfoModal.value = true;
    }
  }
  // After adding, clear modal fields and protoFolders
  modalProfile.value = { id: '', name: '', host: '', port: 50051, tlsEnabled: false, certificatePath: '', useReflection: false };
  protoFolders.value = [];
  showModal.value = false;
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
    showModal.value = false
    // Clear modal fields and protoFolders
    modalProfile.value = { id: '', name: '', host: '', port: 50051, tlsEnabled: false, certificatePath: '', useReflection: false };
    protoFolders.value = [];
  }
}

// Proto folder management
const protoFolders = ref<string[]>([])
const selectedProtoFolder = ref<string | null>(null)
const showInfoModal = ref(false)
const infoModalMessage = ref('')

async function addProtoFolder() {
  // Check required server fields before opening folder picker
  if (!modalProfile.value.name || !modalProfile.value.host || !modalProfile.value.port) {
    infoModalMessage.value = 'Please fill in server name, host, and port before adding proto paths.';
    showInfoModal.value = true;
    return;
  }
  const files = await ImportProtoFilesFromFolder();
  if (!files || files.length === 0) {
    infoModalMessage.value = 'No valid .proto files were found in the selected folder.';
    showInfoModal.value = true;
    return;
  }
  // Get the folder path from the first file (all files are from the same folder)
  const folderPath = files[0].filePath.substring(0, files[0].filePath.lastIndexOf('/'));
  if (!protoFolders.value.includes(folderPath)) {
    protoFolders.value.push(folderPath);
    // Simulate parse: just count files and show modal, do not save to backend
    const okCount = files.length;
    infoModalMessage.value = `Found ${files.length} proto files in folder.`;
    showInfoModal.value = true;
  }
}

function selectProtoFolder(folder: string) {
  selectedProtoFolder.value = folder
}

function removeSelectedProtoFolder() {
  if (selectedProtoFolder.value) {
    protoFolders.value = protoFolders.value.filter(f => f !== selectedProtoFolder.value)
    selectedProtoFolder.value = null
  }
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

const isServerDataValid = computed(() => {
  return !!modalProfile.value.name && !!modalProfile.value.host && !!modalProfile.value.port;
});
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
      <div class="bg-white text-[#222] rounded-lg shadow-lg p-6 w-full max-w-3xl text-[0.8rem] relative">
        <!-- Close (cross) button -->
        <button class="absolute top-2 right-4 text-xl text-gray-400 hover:text-gray-700 font-bold" @click="showModal = false">&times;</button>
        <h3 class="text-lg font-bold mb-4">{{ isEdit ? 'Edit' : 'Add' }} Server Profile</h3>
        <div class="flex flex-row gap-8">
          <!-- Left column: Server data fields -->
          <form class="flex flex-col gap-3 flex-1 min-w-0">
            <input v-model="modalProfile.name" type="text" placeholder="Profile Name" required class="border rounded px-3 py-2" autocomplete="off" />
            <input v-model="modalProfile.host" type="text" placeholder="Host" required class="border rounded px-3 py-2" autocomplete="off" />
            <input v-model.number="modalProfile.port" type="number" placeholder="Port" min="1" required class="border rounded px-3 py-2" autocomplete="off" />
            <label class="flex items-center gap-2">
              <input v-model="modalProfile.tlsEnabled" type="checkbox" /> TLS Enabled
            </label>
            <input v-model="modalProfile.certificatePath" type="text" placeholder="Certificate Path (optional)" class="border rounded px-3 py-2" autocomplete="off" />
            <label class="flex items-center gap-2">
              <input v-model="modalProfile.useReflection" type="checkbox" /> Use Reflection
            </label>
          </form>
          <!-- Right column: Proto folders and files -->
          <div class="flex flex-col flex-1 min-w-0">
            <h4 class="font-semibold mb-2">Proto Folders</h4>
            <div class="border rounded bg-white text-[#222] overflow-y-auto mb-2" style="height: 180px;">
              <div v-for="folder in protoFolders" :key="folder"
                class="px-3 py-1 cursor-pointer select-none"
                :class="{ 'bg-[#42b983] text-white': selectedProtoFolder === folder, 'hover:bg-gray-100': selectedProtoFolder !== folder }"
                @click="selectProtoFolder(folder)"
              >
                {{ folder }}
              </div>
            </div>
            <div class="flex gap-2">
              <button class="bg-[#42b983] text-white rounded px-3 py-1 font-bold hover:bg-[#369870] transition self-start" @click="addProtoFolder">Add proto path</button>
              <button class="bg-red-500 text-white rounded px-3 py-1 font-bold hover:bg-red-700 transition self-start disabled:opacity-50" :disabled="!selectedProtoFolder" @click="removeSelectedProtoFolder">Remove path</button>
            </div>
          </div>
        </div>
        <hr class="my-4 border-t border-gray-300 w-full" />
        <div class="flex gap-2 mt-2 justify-start">
          <button type="button" class="bg-gray-400 text-white rounded px-4 py-1 font-bold hover:bg-gray-600 transition" @click="showModal = false">Cancel</button>
          <button type="button" class="bg-[#42b983] text-white rounded px-4 py-1 font-bold hover:bg-[#369870] transition" @click="saveProfile">Save</button>
        </div>
        <!-- Info Modal for proto file parsing results -->
        <ConfirmModal
          :show="showInfoModal"
          title="Proto File Parsing Results"
          :message="infoModalMessage"
          confirmText="OK"
          :onConfirm="() => { showInfoModal = false }"
          :onCancel="() => { showInfoModal = false }"
        />
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
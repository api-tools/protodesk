<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import { useServerProfileStore } from '@/stores/serverProfile'
import { ListProtoDefinitionsByProfile, SelectProtoFolder, ImportProtoFilesFromFolder, ScanAndParseProtoPath, CreateProtoPath, ListProtoPathsByServer, DeleteProtoPath, ConnectToServer, IsServerConnected } from '@wailsjs/go/app/App'
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
  useReflection: false,
  headers: [] as { key: string, value: string }[]
})

const headersJson = ref('[\n  \n]')
const headersJsonError = ref('')

const showConnectionErrorModal = ref(false)
const connectionErrorMessage = ref('')

const connectionStatus = ref<'connected' | 'not_connected' | 'unknown'>('unknown')
const endpoints = ref<any[]>([])

const selectedProfileId = computed({
  get() {
    return profileStore.activeProfile?.id || ''
  },
  set(id: string) {
    if (id) {
      profileStore.setActiveProfile(id)
    } else {
      profileStore.setActiveProfile(null)
    }
  }
})

const profileIdToDelete = ref<string | null>(null)

const props = defineProps<{ setConnectionStatus?: (status: 'connected' | 'not_connected' | 'unknown') => void }>()

// Add an event emitter for cross-component communication
const emit = defineEmits(['server-profile-updated'])

async function selectProfile(id: string) {
  profileStore.setActiveProfile(id)
  try {
    await ConnectToServer(id)
    // Check connection status
    const isConnected = await IsServerConnected(id)
    connectionStatus.value = isConnected ? 'connected' : 'not_connected'
    props.setConnectionStatus?.(connectionStatus.value)
    // Fetch endpoints (services/methods)
    const defs = await ListProtoDefinitionsByProfile(id)
    endpoints.value = []
    if (defs && defs.length > 0) {
      for (const def of defs) {
        if (def.services && def.services.length > 0) {
          for (const svc of def.services) {
            endpoints.value.push({
              service: svc.name,
              methods: svc.methods ? svc.methods.map(m => m.name) : []
            })
          }
        }
      }
    }
  } catch (e) {
    connectionStatus.value = 'not_connected'
    props.setConnectionStatus?.(connectionStatus.value)
    connectionErrorMessage.value = 'Failed to connect to server: ' + (typeof e === 'string' ? e : (e && typeof e === 'object' && 'message' in e ? (e as any).message : JSON.stringify(e)))
    showConnectionErrorModal.value = true
    console.error('Failed to connect to server:', e)
  }
}

// Proto file management for modal
const protoDefinitions = ref<any[]>([])
async function fetchProtoDefinitions() {
  if (!activeId.value) {
    protoDefinitions.value = []
    return
  }
  try {
    const defs = await ListProtoDefinitionsByProfile(activeId.value)
    protoDefinitions.value = defs || []
  } catch (e) {
    protoDefinitions.value = []
  }
}
watch(() => showModal.value && activeId.value, (val) => {
  if (val) fetchProtoDefinitions()
})

function openAdd() {
  isEdit.value = false
  showModal.value = true
  modalProfile.value = { id: '', name: '', host: '', port: 50051, tlsEnabled: false, certificatePath: '', useReflection: false, headers: [] }
  protoFolders.value = []
}

async function openEdit(profile: any) {
  isEdit.value = true
  showModal.value = true
  modalProfile.value = { ...profile, useReflection: profile.useReflection ?? false, headers: Array.isArray(profile.headers) ? profile.headers : [] }
  // Load proto paths from backend
  try {
    const paths = await ListProtoPathsByServer(profile.id);
    protoFolders.value = Array.isArray(paths) ? paths.map(p => p.Path) : [];
    protoPathIdMap.value = {};
    if (Array.isArray(paths)) {
      for (const p of paths) {
        protoPathIdMap.value[`${profile.id}::${p.Path}`] = p.ID;
      }
    }
  } catch (e) {
    protoFolders.value = [];
    protoPathIdMap.value = {};
  }
}

watch(
  () => showModal.value,
  (val) => {
    if (val) {
      // When opening modal, prefill textarea with new format
      if (modalProfile.value.headers && modalProfile.value.headers.length > 0) {
        headersJson.value = JSON.stringify(
          modalProfile.value.headers.map(h => ({ [h.key]: h.value })),
          null,
          2
        )
      } else {
        headersJson.value = '' // Empty by default
      }
      headersJsonError.value = ''
    }
  }
)

async function saveProfile() {
  // Show error if required fields are missing
  if (!modalProfile.value.name || !modalProfile.value.host || !modalProfile.value.port) {
    headersJsonError.value = 'Please fill in all required fields: name, host, and port.'
    return
  }
  // Parse headersJson only if not empty
  let parsedHeaders: { key: string, value: string }[] = []
  if (headersJson.value.trim() !== '') {
    let parsedHeadersRaw: any[] = []
    try {
      parsedHeadersRaw = JSON.parse(headersJson.value)
      if (!Array.isArray(parsedHeadersRaw)) throw new Error('Headers must be a JSON array')
      for (const obj of parsedHeadersRaw) {
        if (
          typeof obj !== 'object' ||
          obj === null ||
          Array.isArray(obj)
        ) {
          throw new Error('Each header must be an object')
        }
        const keys = Object.keys(obj)
        if (keys.length !== 1) {
          throw new Error('Each header object must have exactly one key')
        }
        const k = keys[0]
        const v = obj[k]
        if (typeof k !== 'string' || typeof v !== 'string') {
          throw new Error('Header name and value must be strings')
        }
        parsedHeaders.push({ key: k, value: v })
      }
      headersJsonError.value = ''
    } catch (e: any) {
      headersJsonError.value = 'Invalid JSON: ' + (e.message || e)
      return
    }
  } else {
    parsedHeaders = []
    headersJsonError.value = ''
  }
  modalProfile.value.headers = parsedHeaders
  let createdProfile;
  if (isEdit.value) {
    await profileStore.updateProfile(modalProfile.value.id, { ...modalProfile.value, protoFolders: [...protoFolders.value], useReflection: modalProfile.value.useReflection, headers: modalProfile.value.headers });
    createdProfile = { id: modalProfile.value.id };
    // If the edited profile is the active one, reconnect and emit event to refresh methods
    if (profileStore.activeProfile?.id === modalProfile.value.id) {
      try {
        await ConnectToServer(modalProfile.value.id)
        emit('server-profile-updated', modalProfile.value.id)
      } catch (e) {
        console.error('Failed to reconnect after editing server:', e)
      }
    }
  } else {
    createdProfile = await profileStore.addProfile({
      ...modalProfile.value,
      id: '',
      createdAt: new Date(),
      updatedAt: new Date(),
      protoFolders: [...protoFolders.value],
      useReflection: modalProfile.value.useReflection,
      headers: modalProfile.value.headers
    });
  }
  // After creating/updating the server, save proto paths and definitions
  for (const folder of protoFolders.value) {
    const key = `${createdProfile.id}::${folder}`;
    // Only create proto path if it is not already in the backend for this server
    if (!protoPathIdMap.value[key]) {
      const protoPathId = Math.random().toString(36).substring(2, 12);
      try {
        await CreateProtoPath(protoPathId, createdProfile.id, folder);
        protoPathIdMap.value[key] = protoPathId; // update map so we don't try again in this session
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
  }
  // After adding, clear modal fields and protoFolders
  modalProfile.value = { id: '', name: '', host: '', port: 50051, tlsEnabled: false, certificatePath: '', useReflection: false, headers: [] };
  protoFolders.value = [];
  showModal.value = false;
  headersJsonError.value = ''
}

const showConfirm = ref(false)
const confirmMessage = ref('Are you sure you want to delete this server profile? This action cannot be undone.')

function handleDeleteClick() {
  if (selectedProfileId.value) {
    profileIdToDelete.value = selectedProfileId.value
    showConfirm.value = true
  }
}
async function handleConfirmDelete() {
  showConfirm.value = false
  if (profileIdToDelete.value) {
    await removeProfile(profileIdToDelete.value)
    profileIdToDelete.value = null
  }
}
function handleCancelDelete() {
  showConfirm.value = false
  profileIdToDelete.value = null
}

async function removeProfile(id: string) {
  await profileStore.removeProfile(id)
  await profileStore.loadProfiles()
  console.log('Profiles after deletion:', profileStore.profiles)
  profileStore.setActiveProfile(null)
  props.setConnectionStatus?.(connectionStatus.value)
  showModal.value = false
  // Clear modal fields and protoFolders
  modalProfile.value = { id: '', name: '', host: '', port: 50051, tlsEnabled: false, certificatePath: '', useReflection: false, headers: [] };
  protoFolders.value = [];
}

// Proto folder management
const protoFolders = ref<string[]>([])
const selectedProtoFolder = ref<string | null>(null)
const showInfoModal = ref(false)
const infoModalMessage = ref('')

const protoPathIdMap = ref<Record<string, string>>({});

const protoPathId = ref('')

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

async function removeSelectedProtoFolder() {
  if (selectedProtoFolder.value) {
    const key = `${modalProfile.value.id}::${selectedProtoFolder.value}`;
    // Remove from backend if it exists
    const pathId = protoPathIdMap.value[key];
    if (pathId) {
      try {
        await DeleteProtoPath(pathId);
      } catch (e) {
        infoModalMessage.value = `Failed to delete proto path: ${selectedProtoFolder.value}. Error: ${e}`;
        showInfoModal.value = true;
        return;
      }
      delete protoPathIdMap.value[key];
    }
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

// Ensure the select resets if the active profile is not in the list
watch(
  () => profileStore.profiles.map(p => p.id),
  (ids) => {
    console.log('Watcher: profiles changed:', ids, 'active:', profileStore.activeProfile?.id)
    if (profileStore.activeProfile && !ids.includes(profileStore.activeProfile.id)) {
      profileStore.setActiveProfile(null)
    }
  }
)
</script>

<template>
  <nav class="w-full bg-[#222c36] text-white px-4 py-2 flex items-center border-b border-[#2c3e50] sticky top-0 z-10 text-[0.8rem]">
    <div class="flex items-center gap-2 flex-wrap w-full">
      <span class="font-semibold">Server:</span>
      <div class="relative min-w-[160px]">
        <select
          class="appearance-none bg-gray-800 border border-[#2c3e50] rounded px-2 py-1 text-white focus:outline-none w-full pr-8 text-[0.8rem]"
          v-model="selectedProfileId"
          @change="selectedProfileId && selectProfile(selectedProfileId)"
        >
          <option disabled value="">-- Select a server --</option>
          <option v-for="profile in profiles" :key="profile.id" :value="profile.id">
            {{ profile.name }}
          </option>
        </select>
      </div>
      <button class="ml-2 px-2 py-0.5 bg-[#42b983] text-white rounded hover:bg-[#369870] transition" @click="openAdd">＋ Add Server</button>
      <button v-if="profileStore.activeProfile?.id" class="text-[#42b983] underline hover:text-[#369870] px-2" @click="openEdit(profiles.find(p => p.id === profileStore.activeProfile?.id))">Edit</button>
      <button v-if="profileStore.activeProfile?.id" class="text-[#42b983] underline hover:text-[#369870] px-2" @click="handleDeleteClick">Delete</button>
      <!-- Debug: manual reload button (optional, can remove if not needed) -->
    </div>
    <!-- Modal -->
    <div v-if="showModal" class="fixed inset-0 bg-black bg-opacity-40 flex items-center justify-center z-50">
      <div class="bg-[#29323b] text-white rounded-lg shadow-lg p-6 w-full max-w-3xl text-[0.8rem] relative">
        <!-- Close (cross) button -->
        <button class="absolute top-2 right-4 text-xl text-gray-400 hover:text-gray-700" @click="showModal = false">&times;</button>
        <h3 class="text-lg font-bold mb-4">{{ isEdit ? 'Edit' : 'Add' }} Server Profile</h3>
        <div class="flex flex-row gap-8">
          <!-- Left column: Server data fields -->
          <form class="flex flex-col gap-3 flex-1 min-w-0">
            <input v-model="modalProfile.name" type="text" placeholder="Profile Name" required class="bg-[#232b36] border border-[#2c3e50] rounded px-2 py-1 text-white focus:outline-none text-[0.8rem]" autocomplete="off" autocorrect="off" autocapitalize="off" />
            <input v-model="modalProfile.host" type="text" placeholder="Host" required class="bg-[#232b36] border border-[#2c3e50] rounded px-2 py-1 text-white focus:outline-none text-[0.8rem]" autocomplete="off" autocorrect="off" autocapitalize="off" />
            <input v-model.number="modalProfile.port" type="number" placeholder="Port" min="1" required class="bg-[#232b36] border border-[#2c3e50] rounded px-2 py-1 text-white focus:outline-none text-[0.8rem]" autocomplete="off" autocorrect="off" autocapitalize="off" />
            <label class="flex items-center gap-2 text-[0.8rem] text-[#b0bec5]">
              <input v-model="modalProfile.tlsEnabled" type="checkbox" class="text-[0.8rem] p-0 m-0" /> TLS Enabled
            </label>
            <input v-model="modalProfile.certificatePath" type="text" placeholder="Certificate Path (optional)" class="bg-[#232b36] border border-[#2c3e50] rounded px-2 py-1 text-white focus:outline-none text-[0.8rem]" autocomplete="off" autocorrect="off" autocapitalize="off" />
            <label class="flex items-center gap-2 text-[0.8rem] text-[#b0bec5]">
              <input v-model="modalProfile.useReflection" type="checkbox" class="text-[0.8rem] p-0 m-0" /> Use Reflection
            </label>
          </form>
          <!-- Right column: Proto folders and files -->
          <div class="flex flex-col flex-1 min-w-0">
            <h4 class="font-semibold mb-2 text-[#b0bec5]">Proto Folders</h4>
            <div class="border border-[#2c3e50] rounded bg-[#232b36] text-white overflow-y-auto mb-2" style="height: 180px;">
              <div v-for="folder in protoFolders" :key="folder"
                class="px-3 py-1 cursor-pointer select-none"
                :class="{ 'bg-[#42b983] text-white': selectedProtoFolder === folder, 'hover:bg-[#374151]': selectedProtoFolder !== folder }"
                @click="selectProtoFolder(folder)"
              >
                {{ folder }}
              </div>
            </div>
            <div class="flex gap-2">
              <button class="bg-[#42b983] text-white rounded px-3 py-1 hover:bg-[#369870] transition self-start" @click="addProtoFolder">Add proto path</button>
              <button class="bg-red-500 text-white rounded px-3 py-1 hover:bg-red-700 transition self-start disabled:opacity-50" :disabled="!selectedProtoFolder" @click="removeSelectedProtoFolder">Remove path</button>
            </div>
          </div>
        </div>
        <div class="mt-6">
          <label class="font-semibold mb-2 block text-[#b0bec5]">Array of headers in JSON format</label>
          <textarea
            v-model="headersJson"
            class="bg-[#232b36] border border-[#2c3e50] rounded px-2 py-1 text-white focus:outline-none w-full font-mono"
            style="height: 120px; resize: none; font-size: 0.8rem; line-height: 1.2;"
            autocomplete="off"
            autocorrect="off"
            autocapitalize="off"
            spellcheck="false"
            placeholder='[\n  { "key": "Authorization", "value": "token" }\n]'
          ></textarea>
          <div v-if="headersJsonError" class="bg-red-700 text-white mt-2 p-2 rounded">{{ headersJsonError }}</div>
        </div>
        <hr class="my-4 border-t border-[#2c3e50] w-full" />
        <div class="flex gap-2 mt-2 justify-start">
          <button type="button" class="bg-[#374151] text-white rounded px-4 py-1 hover:bg-[#232b36] transition" @click="showModal = false">Cancel</button>
          <button type="button" class="bg-[#42b983] text-white rounded px-4 py-1 hover:bg-[#369870] transition" @click="saveProfile">Save</button>
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
    <ConfirmModal
      :show="showConnectionErrorModal"
      title="Connection Error"
      :message="connectionErrorMessage"
      confirmText="OK"
      :onConfirm="() => { showConnectionErrorModal = false }"
      :onCancel="() => { showConnectionErrorModal = false }"
    />
  </nav>
</template> 
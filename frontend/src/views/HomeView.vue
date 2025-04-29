<script setup lang="ts">
import { ref, onMounted, computed, watch } from 'vue'
import { Greet, ListProtoDefinitionsByProfile } from '@wailsjs/go/app/App'
import { useServerProfileStore } from '@/stores/serverProfile'

const name = ref('')
const resultText = ref('')

async function greet() {
  resultText.value = await Greet(name.value)
}

// Server profile form
const profileStore = useServerProfileStore()
const newProfile = ref({
  name: '',
  host: '',
  port: 50051,
  tlsEnabled: false,
  certificatePath: ''
})

const editingProfileId = ref<string | null>(null)
const editProfileData = ref({
  name: '',
  host: '',
  port: 50051,
  tlsEnabled: false,
  certificatePath: ''
})

function addProfile() {
  if (!newProfile.value.name || !newProfile.value.host || !newProfile.value.port) return
  profileStore.addProfile({
    id: Date.now().toString(),
    name: newProfile.value.name,
    host: newProfile.value.host,
    port: Number(newProfile.value.port),
    tlsEnabled: newProfile.value.tlsEnabled,
    certificatePath: newProfile.value.certificatePath || undefined,
    createdAt: new Date(),
    updatedAt: new Date()
  })
  newProfile.value = { name: '', host: '', port: 50051, tlsEnabled: false, certificatePath: '' }
}

function removeProfile(id: string) {
  profileStore.removeProfile(id)
}

function startEditProfile(profile: any) {
  editingProfileId.value = profile.id
  editProfileData.value = {
    name: profile.name,
    host: profile.host,
    port: profile.port,
    tlsEnabled: profile.tlsEnabled,
    certificatePath: profile.certificatePath || ''
  }
}

function saveEditProfile(id: string) {
  profileStore.updateProfile(id, {
    name: editProfileData.value.name,
    host: editProfileData.value.host,
    port: Number(editProfileData.value.port),
    tlsEnabled: editProfileData.value.tlsEnabled,
    certificatePath: editProfileData.value.certificatePath || undefined,
    updatedAt: new Date()
  })
  editingProfileId.value = null
}

function cancelEditProfile() {
  editingProfileId.value = null
}

// Service/method tree state
const protoDefinitions = ref<any[]>([])
const selectedProtoFileId = ref<string | null>(null)
const services = computed(() => {
  // Show services for the selected proto file only
  const def = protoDefinitions.value.find(d => d.id === selectedProtoFileId.value)
  return def ? (def.services || []) : []
})
const selectedService = ref<string | null>(null)
const selectedMethod = ref<string | null>(null)

// Watch for active profile and fetch proto definitions
const activeProfile = computed(() => profileStore.activeProfile)

async function fetchProtoDefinitions() {
  if (!activeProfile.value) {
    protoDefinitions.value = []
    return
  }
  try {
    const defs = await ListProtoDefinitionsByProfile(activeProfile.value.id)
    protoDefinitions.value = defs || []
  } catch (e) {
    protoDefinitions.value = []
  }
}

watch(activeProfile, fetchProtoDefinitions, { immediate: true })

function selectMethod(serviceName: string, methodName: string) {
  selectedService.value = serviceName
  selectedMethod.value = methodName
}

function selectProtoFile(id: string) {
  selectedProtoFileId.value = id
  selectedService.value = null
  selectedMethod.value = null
}

// Instead, aggregate all services from all proto definitions for the active profile
const allServices = computed(() => {
  const result: { name: string, methods: any[] }[] = []
  for (const def of protoDefinitions.value) {
    if (def.services && def.services.length > 0) {
      for (const svc of def.services) {
        result.push({
          name: svc.name,
          methods: svc.methods || []
        })
      }
    }
  }
  return result
})

onMounted(() => {
  profileStore.loadProfiles()
})
</script>

<template>
  <div class="flex flex-row w-full text-[0.8rem] overflow-hidden" style="height: 100vh; overflow: hidden;">
    <!-- Left column: Service/Method Tree -->
    <section class="flex flex-col flex-[2] min-w-[180px] max-w-[320px] h-full border-r border-[#2c3e50] bg-[#202733] p-6">
      <h2 class="font-bold text-white mb-2">Services & Methods</h2>
      <div v-if="allServices.length === 0" class="bg-[#29323b] rounded p-4 text-[#b0bec5] mt-2">
        No proto services found for this server.
      </div>
      <div v-else class="mt-2 space-y-4 overflow-y-auto">
        <div v-for="service in allServices" :key="service.name">
          <div class="font-semibold text-white mb-1">{{ service.name }}</div>
          <div v-for="method in service.methods" :key="method.name"
               class="ml-4 px-2 py-1 rounded cursor-pointer text-[#b0bec5] hover:bg-[#2c3e50] hover:text-white"
               @click="selectMethod(service.name, method.name)">
            {{ method.name }}
          </div>
        </div>
      </div>
    </section>
    <!-- Middle column: Request Builder -->
    <section class="flex flex-col flex-[3] h-full border-r border-[#2c3e50] bg-[#232b36] p-6">
      <h2 class="font-bold text-white mb-2">Request Builder</h2>
      <div class="bg-[#29323b] rounded p-4 text-[#b0bec5] mt-2 flex-1">[Dynamic Request Form Here]</div>
      <button class="mt-4 px-6 py-2 bg-[#42b983] text-[#222] rounded font-bold hover:bg-[#369870] transition self-start">Send</button>
    </section>
    <!-- Right column: Response Viewer -->
    <section class="flex flex-col flex-[4] h-full bg-[#232b36] p-6">
      <h2 class="font-bold text-white mb-2">Response</h2>
      <div class="bg-[#29323b] rounded p-4 text-[#b0bec5] mt-2 flex-1">[Response Viewer Here]</div>
    </section>
  </div>
</template>

<style scoped>
.flex-row {
  min-height: 0;
  flex: 1 1 0%;
}
.app, html, body {
  height: 100%;
  min-height: 0;
}
</style>

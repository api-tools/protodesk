<script setup lang="ts">
import { ref, onMounted, computed, watch } from 'vue'
import { Greet, ListProtoDefinitionsByProfile, ListServerServices, ConnectToServer, GetMethodInputDescriptor } from '@wailsjs/go/app/App'
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

const reflectionServices = ref<{ [service: string]: string[] } | null>(null)
const reflectionError = ref<string | null>(null)
const connectionLoading = ref(false)
const connectionError = ref<string | null>(null)

const reflectionInputFields = ref<any[]>([])
const inputFieldsLoading = ref(false)
const inputFieldsError = ref<string | null>(null)

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

async function fetchServicesAndMethods() {
  if (!activeProfile.value) {
    reflectionServices.value = null
    protoDefinitions.value = []
    reflectionError.value = null
    connectionError.value = null
    connectionLoading.value = false
    return
  }
  if (activeProfile.value.useReflection) {
    connectionLoading.value = true
    connectionError.value = null
    try {
      await ConnectToServer(activeProfile.value.id)
      connectionLoading.value = false
      try {
        const result = await ListServerServices(activeProfile.value.id)
        reflectionServices.value = result
        reflectionError.value = null
      } catch (e: any) {
        reflectionServices.value = null
        reflectionError.value = e?.message || 'Reflection failed.'
      }
    } catch (e: any) {
      connectionLoading.value = false
      connectionError.value = e?.message || 'Failed to connect to server.'
      reflectionServices.value = null
      reflectionError.value = null
    }
  } else {
    await fetchProtoDefinitions()
    reflectionServices.value = null
    reflectionError.value = null
    connectionError.value = null
    connectionLoading.value = false
  }
}

watch(activeProfile, fetchServicesAndMethods, { immediate: true })

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
  if (reflectionServices.value) {
    // Reflection: build [{ name, methods: [{ name }] }]
    return Object.entries(reflectionServices.value).map(([svc, methods]) => ({
      name: svc,
      methods: methods.map(m => ({ name: m }))
    }))
  }
  // Fallback: aggregate from protoDefinitions
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

const expandedServices = ref<Record<string, boolean>>({})

function toggleService(serviceName: string) {
  expandedServices.value[serviceName] = !expandedServices.value[serviceName]
}

const requestData = ref<Record<string, any>>({})
const responseData = ref<any>(null)

watch([selectedService, selectedMethod, activeProfile, reflectionServices], async ([svc, mth, profile, refl]) => {
  if (!inputFieldsLoading) return; // Defensive: should always be defined, but just in case

  if (profile && profile.useReflection && svc && mth && reflectionServices.value) {
    inputFieldsLoading.value = true;
    inputFieldsError.value = null;
    try {
      const fields = await GetMethodInputDescriptor(profile.id, svc, mth);
      reflectionInputFields.value = fields || [];
      inputFieldsLoading.value = false;
      // Initialize requestData
      const data: Record<string, any> = {};
      for (const field of fields) {
        data[field.name] = field.isRepeated ? [] : '';
      }
      requestData.value = data;
    } catch (e: any) {
      reflectionInputFields.value = [];
      inputFieldsLoading.value = false;
      inputFieldsError.value = e?.message || 'Failed to fetch input fields.';
      requestData.value = {};
    }
  } else if (svc && mth) {
    // Fallback: proto definitions logic
    const method = allServices.value
      .find(svcObj => svcObj.name === svc)?.methods
      .find(m => m.name === mth)
    if (method && method.inputType && Array.isArray(method.inputType.fields)) {
      const fields = method.inputType.fields
      const data: Record<string, any> = {}
      for (const field of fields) {
        data[field.name] = field.isRepeated ? [] : ''
      }
      requestData.value = data
    } else {
      requestData.value = {}
    }
    reflectionInputFields.value = []
    inputFieldsLoading.value = false
    inputFieldsError.value = null
  } else {
    requestData.value = {}
    reflectionInputFields.value = []
    inputFieldsLoading.value = false
    inputFieldsError.value = null
  }
}, { immediate: true })

function handleInputChange(field: any, value: any) {
  requestData.value[field.name] = value
}

function handleSend() {
  // For now, just echo the requestData as a simulated response
  responseData.value = JSON.stringify(requestData.value, null, 2)
}

function addRepeatedField(fieldName: string) {
  if (!Array.isArray(requestData.value[fieldName])) {
    requestData.value[fieldName] = []
  }
  requestData.value[fieldName].push('')
}

function removeRepeatedField(fieldName: string, idx: number) {
  if (Array.isArray(requestData.value[fieldName])) {
    requestData.value[fieldName].splice(idx, 1)
  }
}

onMounted(() => {
  profileStore.loadProfiles()
})
</script>

<template>
  <div class="flex flex-row w-full text-[0.8rem] overflow-hidden" style="height: 100vh; overflow: hidden;">
    <!-- Left column: Service/Method Tree -->
    <section class="flex flex-col flex-[2] min-w-[180px] max-w-[320px] h-full border-r border-[#2c3e50] bg-[#202733] p-3">
      <h2 class="font-bold text-white mb-2">Services & Methods</h2>
      <div v-if="connectionLoading" class="bg-blue-900 text-blue-200 rounded p-2 mb-2">Connecting to server...</div>
      <div v-if="connectionError" class="bg-red-900 text-red-200 rounded p-2 mb-2">{{ connectionError }}</div>
      <div v-if="reflectionError" class="bg-red-900 text-red-200 rounded p-2 mb-2">{{ reflectionError }}</div>
      <div v-if="allServices.length === 0 && !connectionLoading" class="bg-[#29323b] rounded p-4 text-[#b0bec5] mt-2">
        No proto services found for this server.
      </div>
      <div v-else-if="!connectionLoading" class="mt-2 space-y-2 overflow-y-auto">
        <div v-for="service in allServices" :key="service.name" class="">
          <div class="flex items-center cursor-pointer select-none" @click="toggleService(service.name)">
            <span class="mr-1 text-[#b0bec5]">
              <span v-if="expandedServices[service.name]">▼</span>
              <span v-else>▶</span>
            </span>
            <span class="font-semibold text-white">{{ service.name }}</span>
          </div>
          <transition name="fade">
            <div v-show="expandedServices[service.name] !== false" class="ml-5 mt-1 space-y-1">
              <div v-for="method in service.methods" :key="method.name"
                   class="px-2 py-1 rounded cursor-pointer text-[#b0bec5] hover:bg-[#2c3e50] hover:text-white"
                   :class="{ 'bg-[#2c3e50] text-white': selectedService === service.name && selectedMethod === method.name }"
                   @click.stop="selectMethod(service.name, method.name)">
                {{ method.name }}
              </div>
            </div>
          </transition>
        </div>
      </div>
    </section>
    <!-- Middle column: Request Builder -->
    <section class="flex flex-col flex-[3] h-full border-r border-[#2c3e50] bg-[#232b36] p-3">
      <div class="flex items-center justify-between mb-2">
        <h2 class="font-bold text-white">Request Builder</h2>
        <button v-if="selectedService && selectedMethod" class="px-3 py-1 bg-[#42b983] text-[#222] rounded font-bold hover:bg-[#369870] transition ml-4" @click="handleSend">Send</button>
      </div>
      <hr class="border-t border-[#2c3e50] mb-3" />
      <div v-if="inputFieldsLoading" class="bg-blue-900 text-blue-200 rounded p-2 mb-2">Loading request fields...</div>
      <div v-if="inputFieldsError" class="bg-red-900 text-red-200 rounded p-2 mb-2">{{ inputFieldsError }}</div>
      <form v-if="selectedService && selectedMethod && ((reflectionInputFields.length > 0 && reflectionInputFields.some(f => !f.isRepeated || (f.isRepeated && requestData[f.name] && requestData[f.name].length > 0))) || allServices.find(svc => svc.name === selectedService)?.methods.find(m => m.name === selectedMethod)?.inputType?.fields?.length)" @submit.prevent>
        <div v-for="field in (reflectionInputFields.length > 0 ? reflectionInputFields : allServices.find(svc => svc.name === selectedService)?.methods.find(m => m.name === selectedMethod)?.inputType.fields || [])" :key="field.name" class="mb-3">
          <div class="flex items-center justify-between mb-1">
            <label class="block text-white font-semibold">{{ field.name }} <span class="text-[#42b983]">({{ field.type }}<span v-if="field.isRepeated">[]</span>)</span></label>
            <button v-if="field.isRepeated" type="button" class="text-[#42b983] hover:text-[#369870] flex items-center justify-center rounded-full w-5 h-5" style="border: none; background: none; padding: 0;" @click="addRepeatedField(field.name)">
              <span aria-label="Add" title="Add"><svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" fill="currentColor" viewBox="0 0 20 20"><circle cx="10" cy="10" r="8" stroke="#42b983" stroke-width="2" fill="none"/><line x1="10" y1="6" x2="10" y2="14" stroke="#42b983" stroke-width="2"/><line x1="6" y1="10" x2="14" y2="10" stroke="#42b983" stroke-width="2"/></svg></span>
            </button>
          </div>
          <!-- Repeated fields -->
          <template v-if="field.isRepeated">
            <div v-for="(val, idx) in requestData[field.name]" :key="idx" class="flex items-center mb-1">
              <div class="flex-1 flex items-center">
                <input
                  v-if="field.type === 'string' || field.type === 'int32' || field.type === 'int64' || field.type === 'float' || field.type === 'double' || field.type === 'uint32' || field.type === 'uint64' || field.type === 'fixed32' || field.type === 'fixed64' || field.type === 'sfixed32' || field.type === 'sfixed64' || field.type === 'sint32' || field.type === 'sint64'"
                  :type="field.type === 'string' ? 'text' : 'number'"
                  class="w-full px-2 py-1 rounded bg-[#232b36] border border-[#2c3e50] text-white focus:outline-none text-[0.8rem]"
                  v-model="requestData[field.name][idx]"
                  :placeholder="field.type"
                  :autocomplete="'off'"
                  :autocorrect="'off'"
                />
                <select
                  v-else-if="field.type === 'enum' && field.enumValues && field.enumValues.length > 0"
                  class="w-full px-2 py-1 rounded bg-[#232b36] border border-[#2c3e50] text-white focus:outline-none text-[0.8rem]"
                  v-model="requestData[field.name][idx]"
                  :autocomplete="'off'"
                  :autocorrect="'off'"
                >
                  <option v-for="ev in field.enumValues" :key="ev" :value="ev">{{ ev }}</option>
                </select>
                <input
                  v-else-if="field.type === 'bool'"
                  type="checkbox"
                  v-model="requestData[field.name][idx]"
                  class="text-[0.8rem] p-0 m-0"
                  :autocomplete="'off'"
                  :autocorrect="'off'"
                />
                <input
                  v-else-if="field.type === 'bytes'"
                  type="text"
                  class="w-full px-2 py-1 rounded bg-[#232b36] border border-[#2c3e50] text-white focus:outline-none text-[0.8rem]"
                  v-model="requestData[field.name][idx]"
                  :placeholder="'base64 string'"
                  :autocomplete="'off'"
                  :autocorrect="'off'"
                />
                <span v-else-if="field.type === 'message'" class="italic text-[#b0bec5]">Nested message fields are not yet supported.</span>
                <span v-else-if="field.type === 'group'" class="italic text-[#b0bec5]">Group fields are not supported (legacy protobuf feature).</span>
                <span v-else class="italic text-[#b0bec5]">Unsupported type: {{ field.type }}</span>
              </div>
              <button type="button" class="ml-2 flex items-center justify-center rounded-full w-5 h-5" style="border: none; background: none; padding: 0;" @click="removeRepeatedField(field.name, idx)">
                <span aria-label="Remove" title="Remove"><svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" fill="currentColor" viewBox="0 0 20 20"><circle cx="10" cy="10" r="8" stroke="#e3342f" stroke-width="2" fill="none"/><line x1="6" y1="10" x2="14" y2="10" stroke="#e3342f" stroke-width="2"/></svg></span>
              </button>
            </div>
          </template>
          <!-- Non-repeated fields -->
          <template v-else>
            <input
              v-if="field.type === 'string' || field.type === 'int32' || field.type === 'int64' || field.type === 'float' || field.type === 'double' || field.type === 'uint32' || field.type === 'uint64' || field.type === 'fixed32' || field.type === 'fixed64' || field.type === 'sfixed32' || field.type === 'sfixed64' || field.type === 'sint32' || field.type === 'sint64'"
              :type="field.type === 'string' ? 'text' : 'number'"
              class="w-full px-2 py-1 rounded bg-[#232b36] border border-[#2c3e50] text-white focus:outline-none text-[0.8rem]"
              v-model="requestData[field.name]"
              :placeholder="field.type"
              :autocomplete="'off'"
              :autocorrect="'off'"
            />
            <select
              v-else-if="field.type === 'enum' && field.enumValues && field.enumValues.length > 0"
              class="w-full px-2 py-1 rounded bg-[#232b36] border border-[#2c3e50] text-white focus:outline-none text-[0.8rem]"
              v-model="requestData[field.name]"
              :autocomplete="'off'"
              :autocorrect="'off'"
            >
              <option v-for="ev in field.enumValues" :key="ev" :value="ev">{{ ev }}</option>
            </select>
            <label v-else-if="field.type === 'bool'" :key="field.name" class="flex items-center gap-2 text-[0.8rem]">
              <input type="checkbox" v-model="requestData[field.name]" class="text-[0.8rem] p-0 m-0" />
              {{ field.name }}
            </label>
            <input
              v-else-if="field.type === 'bytes'"
              type="text"
              class="w-full px-2 py-1 rounded bg-[#232b36] border border-[#2c3e50] text-white focus:outline-none text-[0.8rem]"
              v-model="requestData[field.name]"
              :placeholder="'base64 string'"
              :autocomplete="'off'"
              :autocorrect="'off'"
            />
            <span v-else-if="field.type === 'message'" class="italic text-[#b0bec5]">Nested message fields are not yet supported.</span>
            <span v-else-if="field.type === 'group'" class="italic text-[#b0bec5]">Group fields are not supported (legacy protobuf feature).</span>
            <span v-else class="italic text-[#b0bec5]">Unsupported type: {{ field.type }}</span>
          </template>
        </div>
      </form>
      <div v-else-if="selectedService && selectedMethod && !inputFieldsLoading && !inputFieldsError" class="text-[#b0bec5] mt-2">
        This method does not require any input.
      </div>
    </section>
    <!-- Right column: Response Viewer -->
    <section class="flex flex-col flex-[4] h-full bg-[#232b36] p-3">
      <div class="flex items-center justify-between mb-2">
        <h2 class="font-bold text-white">Response</h2>
      </div>
      <hr class="border-t border-[#2c3e50] mb-3" />
      <div class="flex-1 text-[#b0bec5] whitespace-pre-wrap font-mono">
        <span v-if="responseData">{{ responseData }}</span>
        <span v-else class="italic">[No response yet]</span>
      </div>
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
.fade-enter-active, .fade-leave-active {
  transition: opacity 0.2s;
}
.fade-enter-from, .fade-leave-to {
  opacity: 0;
}
</style>

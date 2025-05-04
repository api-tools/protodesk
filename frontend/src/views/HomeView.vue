<script setup lang="ts">
import { ref, onMounted, computed, watch, onUnmounted } from 'vue'
import { Greet, ListProtoDefinitionsByProfile, ListServerServices, ConnectToServer, GetMethodInputDescriptor, SavePerRequestHeaders, GetPerRequestHeaders, CallGRPCMethod } from '@wailsjs/go/app/App'
import { useServerProfileStore } from '@/stores/serverProfile'
import ProtoMessageField from '@/components/ProtoMessageField.vue'
import ResponseViewer from '@/components/ResponseViewer.vue'
import PreviewModal from '@/components/PreviewModal.vue'

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
let isUnmounted = false;
onUnmounted(() => {
  isUnmounted = true;
});
const inputFieldsError = ref<string | null>(null)

const perRequestHeadersJson = ref('')
const perRequestHeaders = ref<{ key: string, value: string }[]>([])
const perRequestHeadersError = ref('')
const showHeadersModal = ref(false)
const showPreviewModal = ref(false)
const previewRequestJSON = computed(() => {
  try {
    return JSON.stringify(requestData.value, null, 2)
  } catch {
    return '[Invalid request data]'
  }
})
const previewHeadersJSON = computed(() => {
  try {
    const merged = mergeHeaders(serverHeaders.value, perRequestHeaders.value)
    return JSON.stringify(merged, null, 2)
  } catch {
    return '[Invalid headers]'
  }
})

// Helper: get server headers from active profile
const serverHeaders = computed(() => {
  return (activeProfile.value && Array.isArray(activeProfile.value.headers)) ? activeProfile.value.headers : []
})

function openHeadersModal() {
  // Prefill with last used per-request headers, or server headers if empty
  if (perRequestHeaders.value.length > 0) {
    perRequestHeadersJson.value = JSON.stringify(
      perRequestHeaders.value.map(h => ({ [h.key]: h.value })),
      null,
      2
    )
  } else if (serverHeaders.value.length > 0) {
    perRequestHeadersJson.value = JSON.stringify(
      serverHeaders.value.map(h => ({ [h.key]: h.value })),
      null,
      2
    )
  } else {
    perRequestHeadersJson.value = ''
  }
  perRequestHeadersError.value = ''
  showHeadersModal.value = true
}

// When a method is selected, load per-request headers from backend
async function loadHeadersForMethod() {
  if (!activeProfile.value || !selectedService.value || !selectedMethod.value) {
    perRequestHeaders.value = []
    perRequestHeadersJson.value = ''
    return
  }
  try {
    const json = await GetPerRequestHeaders(
      activeProfile.value.id,
      selectedService.value,
      selectedMethod.value
    )
    if (json && json.trim() !== '') {
      perRequestHeadersJson.value = json
      // Parse and set perRequestHeaders.value
      const arr = JSON.parse(json)
      perRequestHeaders.value = arr.map((obj: Record<string, string>) => {
        const k = Object.keys(obj)[0]
        return { key: k, value: obj[k] }
      })
    } else {
      // Fallback to server headers
      perRequestHeaders.value = []
      perRequestHeadersJson.value = JSON.stringify(
        serverHeaders.value.map(h => ({ [h.key]: h.value })),
        null,
        2
      )
    }
  } catch (e) {
    // Not found: fallback to server headers
    perRequestHeaders.value = []
    perRequestHeadersJson.value = JSON.stringify(
      serverHeaders.value.map(h => ({ [h.key]: h.value })),
      null,
      2
    )
  }
}

// Watch for method selection to load headers
watch([selectedService, selectedMethod, activeProfile], async ([svc, mth, profile]) => {
  if (svc && mth && profile) {
    await loadHeadersForMethod()
  }
})

async function savePerRequestHeaders() {
  // Validate JSON
  if (perRequestHeadersJson.value.trim() === '') {
    perRequestHeaders.value = []
    perRequestHeadersError.value = ''
    showHeadersModal.value = false
    // Save empty to backend (delete per-request headers)
    if (activeProfile.value && selectedService.value && selectedMethod.value) {
      await SavePerRequestHeaders(
        activeProfile.value.id,
        selectedService.value,
        selectedMethod.value,
        ''
      )
    }
    return
  }
  let parsed: { key: string, value: string }[] = []
  try {
    const arr = JSON.parse(perRequestHeadersJson.value)
    if (!Array.isArray(arr)) throw new Error('Headers must be a JSON array')
    for (const obj of arr) {
      if (typeof obj !== 'object' || obj === null || Array.isArray(obj)) throw new Error('Each header must be an object')
      const keys = Object.keys(obj)
      if (keys.length !== 1) throw new Error('Each header object must have exactly one key')
      const k = keys[0]
      const v = obj[k]
      if (typeof k !== 'string' || typeof v !== 'string') throw new Error('Header name and value must be strings')
      parsed.push({ key: k, value: v })
    }
    perRequestHeaders.value = parsed
    perRequestHeadersError.value = ''
    showHeadersModal.value = false
    // Save to backend
    if (activeProfile.value && selectedService.value && selectedMethod.value) {
      await SavePerRequestHeaders(
        activeProfile.value.id,
        selectedService.value,
        selectedMethod.value,
        perRequestHeadersJson.value
      )
    }
  } catch (e: any) {
    perRequestHeadersError.value = 'Invalid JSON: ' + (e.message || e)
  }
}

function resetHeadersToServerDefault() {
  if (serverHeaders.value.length > 0) {
    perRequestHeadersJson.value = JSON.stringify(
      serverHeaders.value.map(h => ({ [h.key]: h.value })),
      null,
      2
    )
  } else {
    perRequestHeadersJson.value = ''
  }
  perRequestHeadersError.value = ''
}

// Use only per-request headers if present, otherwise server headers
const mergedHeaders = computed(() => {
  if (perRequestHeaders.value.length > 0) {
    return perRequestHeaders.value
  }
  return serverHeaders.value
})

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
  if (!inputFieldsLoading || typeof inputFieldsLoading.value === 'undefined' || isUnmounted) return;

  if (profile && profile.useReflection && svc && mth && reflectionServices.value) {
    if (!isUnmounted && inputFieldsLoading && typeof inputFieldsLoading.value !== 'undefined') inputFieldsLoading.value = true;
    inputFieldsError.value = null;
    try {
      let fields = await GetMethodInputDescriptor(profile.id, svc, mth);
      if (!Array.isArray(fields)) fields = [];
      reflectionInputFields.value = fields;
      console.log('Reflection fields:', fields);
      if (!isUnmounted && inputFieldsLoading && typeof inputFieldsLoading.value !== 'undefined') inputFieldsLoading.value = false;
      // Initialize requestData
      const data: Record<string, any> = {};
      for (const field of fields) {
        if (field.type === 'bool') {
          data[field.name] = false;
        } else if (field.type === 'message') {
          data[field.name] = null;
        } else {
          data[field.name] = field.isRepeated ? [] : '';
        }
      }
      requestData.value = data;
    } catch (e: any) {
      reflectionInputFields.value = [];
      if (!isUnmounted && inputFieldsLoading && typeof inputFieldsLoading.value !== 'undefined') inputFieldsLoading.value = false;
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
        if (field.type === 'bool') {
          data[field.name] = false;
        } else if (field.type === 'message') {
          data[field.name] = null;
        } else {
          data[field.name] = field.isRepeated ? [] : ''
        }
      }
      requestData.value = data
      reflectionInputFields.value = []
      if (!isUnmounted && inputFieldsLoading && typeof inputFieldsLoading.value !== 'undefined') inputFieldsLoading.value = false
      inputFieldsError.value = null
    } else {
      requestData.value = {}
      reflectionInputFields.value = []
      if (!isUnmounted && inputFieldsLoading && typeof inputFieldsLoading.value !== 'undefined') inputFieldsLoading.value = false
      inputFieldsError.value = null
    }
  } else {
    requestData.value = {}
    reflectionInputFields.value = []
    if (!isUnmounted && inputFieldsLoading && typeof inputFieldsLoading.value !== 'undefined') inputFieldsLoading.value = false
    inputFieldsError.value = null
  }
}, { immediate: true })

function handleInputChange(field: any, value: any) {
  requestData.value[field.name] = value
}

const sendLoading = ref(false)
const sendError = ref('')

function mergeHeaders(serverHeaders: { key: string, value: string }[], perRequestHeaders: { key: string, value: string }[]) {
  // Per-request headers override server headers
  const merged: Record<string, string> = {}
  for (const h of serverHeaders) {
    merged[h.key] = h.value
  }
  for (const h of perRequestHeaders) {
    merged[h.key] = h.value
  }
  return merged
}

function fixRequestDataForProto(input: Record<string, any>, fields: any[]): Record<string, any> {
  const fixed = { ...input }
  fields.forEach((field: any) => {
    if ([
      'int32', 'int64', 'uint32', 'uint64',
      'fixed32', 'fixed64', 'sfixed32', 'sfixed64',
      'sint32', 'sint64', 'float', 'double'
    ].includes(field.type) && fixed[field.name] === '') {
      fixed[field.name] = null
    } else if (field.type === 'message') {
      if (fixed[field.name] === '' || fixed[field.name] === null) {
        fixed[field.name] = null
      } else if (typeof fixed[field.name] === 'object') {
        fixed[field.name] = fixRequestDataForProto(fixed[field.name], field.fields)
        // If all subfields are null/empty/empty array, set to null
        if (Object.values(fixed[field.name]).every(v => v === null || v === '' || (Array.isArray(v) && v.length === 0))) {
          fixed[field.name] = null
        }
      }
    }
  })
  return fixed
}

async function handleSend() {
  sendLoading.value = true
  sendError.value = ''
  responseData.value = null
  try {
    if (!activeProfile.value || !selectedService.value || !selectedMethod.value) {
      sendError.value = 'Missing profile, service, or method.'
      sendLoading.value = false
      return
    }
    // Prepare request data, converting empty numeric fields to null
    const fields = (reflectionInputFields.value.length > 0
      ? reflectionInputFields.value
      : (allServices.value.find(svc => svc.name === selectedService.value)?.methods.find(m => m.name === selectedMethod.value)?.inputType.fields || []))
    const fixedRequestData = fixRequestDataForProto(requestData.value, fields)
    let requestJSON = ''
    try {
      requestJSON = JSON.stringify(fixedRequestData)
    } catch (e) {
      sendError.value = e instanceof Error ? 'Invalid request data: ' + e.message : 'Invalid request data: ' + String(e)
      sendLoading.value = false
      return
    }
    // Merge headers
    const merged = mergeHeaders(serverHeaders.value, perRequestHeaders.value)
    let headersJSON = ''
    try {
      headersJSON = JSON.stringify(merged)
    } catch (e) {
      sendError.value = e instanceof Error ? 'Invalid headers: ' + e.message : 'Invalid headers: ' + String(e)
      sendLoading.value = false
      return
    }
    // Call backend
    const resp = await CallGRPCMethod(
      activeProfile.value.id,
      selectedService.value,
      selectedMethod.value,
      requestJSON,
      headersJSON
    )
    responseData.value = resp
  } catch (e) {
    sendError.value = e instanceof Error ? e.message : String(e)
  } finally {
    sendLoading.value = false
  }
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

const formattedResponse = computed(() => {
  if (!responseData.value) return ''
  try {
    // Try to pretty-print JSON
    return JSON.stringify(JSON.parse(responseData.value), null, 2)
  } catch {
    // Fallback to plain text
    return responseData.value
  }
})

const previewGrpcurlCommand = computed(() => {
  if (!activeProfile.value || !selectedService.value || !selectedMethod.value) return ''
  const address = `${activeProfile.value.host}:${activeProfile.value.port}`
  const headers = mergeHeaders(serverHeaders.value, perRequestHeaders.value)
  const headerFlags = Object.entries(headers)
    .map(([k, v]) => `-H '${k}: ${v}'`)
    .join(' ')
  // Use the same fixRequestDataForProto logic for preview
  const fields = (reflectionInputFields.value.length > 0
    ? reflectionInputFields.value
    : (allServices.value.find(svc => svc.name === selectedService.value)?.methods.find(m => m.name === selectedMethod.value)?.inputType.fields || []))
  let dataFlag = ''
  try {
    const fixedRequestData = fixRequestDataForProto(requestData.value, fields)
    dataFlag = `-d '${JSON.stringify(fixedRequestData)}'`
  } catch {
    dataFlag = ''
  }
  const tlsFlag = activeProfile.value.tlsEnabled ? '' : '-plaintext'
  const certFlag = activeProfile.value.certificatePath ? `-cacert '${activeProfile.value.certificatePath}'` : ''
  const serviceMethod = `${selectedService.value}/${selectedMethod.value}`
  return `grpcurl ${tlsFlag} ${certFlag} ${headerFlags} ${dataFlag} ${address} ${serviceMethod}`.replace(/ +/g, ' ').trim()
})

const topLevelMessageExpanded = ref<Record<string, boolean>>({})
function toggleTopLevelMessageField(name: string) {
  topLevelMessageExpanded.value[name] = !topLevelMessageExpanded.value[name]
}

const methodSearch = ref('')

const filteredServices = computed(() => {
  if (!methodSearch.value.trim()) return allServices.value
  const search = methodSearch.value.trim().toLowerCase()
  return allServices.value
    .map(service => {
      const matchingMethods = service.methods.filter(m => m.name.toLowerCase().includes(search))
      if (matchingMethods.length > 0) {
        return { ...service, methods: matchingMethods }
      }
      return undefined
    })
    .filter((svc): svc is { name: string, methods: any[] } => !!svc)
})

onMounted(() => {
  profileStore.loadProfiles()
})
</script>

<template>
  <div class="flex flex-row w-full text-[0.8rem] overflow-hidden" style="height: 100vh; overflow: hidden;">
    <!-- Left column: Service/Method Tree -->
    <section class="flex flex-col flex-1 h-full border-r border-[#2c3e50] bg-[#202733] p-3 scrollable-column">
      <div class="flex items-center justify-between mb-2 min-h-[40px]">
        <h2 class="font-bold text-white whitespace-nowrap">Services & Methods</h2>
        <div class="relative ml-2 flex-1 max-w-xs">
          <input
            v-model="methodSearch"
            type="text"
            placeholder="Search methods..."
            class="bg-[#232b36] border border-[#2c3e50] rounded px-2 py-1 text-xs text-white focus:outline-none w-full pr-6"
            style="min-width: 120px;"
          />
          <button v-if="methodSearch" @click="methodSearch = ''" class="absolute right-1 top-1/2 -translate-y-1/2 text-[#b0bec5] hover:text-white text-xs px-1 py-0.5 rounded focus:outline-none" style="background: none; border: none;">
            &times;
          </button>
        </div>
      </div>
      <hr class="border-t border-[#2c3e50] mb-3" />
      <div v-if="connectionLoading" class="bg-blue-900 text-blue-200 rounded p-2 mb-2">Connecting to server...</div>
      <div v-if="connectionError" class="bg-red-900 text-red-200 rounded p-2 mb-2">{{ connectionError }}</div>
      <div v-if="reflectionError" class="bg-red-900 text-red-200 rounded p-2 mb-2">{{ reflectionError }}</div>
      <div v-if="allServices.length === 0 && !connectionLoading" class="bg-[#29323b] rounded p-4 text-[#b0bec5] mt-2">
        No proto services found for this server.
      </div>
      <div v-else-if="!connectionLoading" class="mt-2 space-y-2 overflow-y-auto">
        <div v-for="service in filteredServices" :key="service.name" class="">
          <div class="flex items-center select-none">
            <span class="mr-1 cursor-pointer flex items-center" @click.stop="toggleService(service.name)">
              <span v-if="expandedServices[service.name]">
                <!-- Down chevron SVG -->
                <svg width="14" height="14" viewBox="0 0 20 20" fill="none"><path d="M6 8l4 5 4-5" stroke="#b0bec5" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>
              </span>
              <span v-else>
                <!-- Right chevron SVG -->
                <svg width="14" height="14" viewBox="0 0 20 20" fill="none"><path d="M7 6l5 4-5 4" stroke="#b0bec5" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>
              </span>
            </span>
            <span class="font-semibold text-white cursor-pointer" @click="toggleService(service.name)">{{ service.name }}</span>
          </div>
          <transition name="fade">
            <div v-show="expandedServices[service.name] || methodSearch" class="ml-5 mt-1 space-y-1">
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
    <section class="flex flex-col flex-1 h-full border-r border-[#2c3e50] bg-[#232b36] p-3 scrollable-column">
      <div class="flex items-center justify-between mb-2 min-h-[40px]">
        <h2 class="font-bold text-white whitespace-nowrap">Request Builder</h2>
        <div class="flex items-center gap-2 w-full">
          <div class="flex-1"></div>
          <span v-if="selectedService && selectedMethod" class="text-[#42b983] underline hover:text-[#369870] text-xs ml-2 cursor-pointer" @click="openHeadersModal">Edit Headers</span>
          <span v-if="selectedService && selectedMethod" class="text-[#42b983] underline hover:text-[#369870] text-xs ml-2 cursor-pointer" @click="showPreviewModal = true">Preview</span>
          <button v-if="selectedService && selectedMethod" class="px-3 py-1 bg-[#42b983] text-white rounded font-bold hover:bg-[#369870] transition ml-4" @click="handleSend" style="margin-left:auto;">Send</button>
        </div>
      </div>
      <hr class="border-t border-[#2c3e50] mb-3" />
      <div v-if="inputFieldsLoading" class="bg-blue-900 text-blue-200 rounded p-2 mb-2">Loading request fields...</div>
      <div v-if="inputFieldsError" class="bg-red-900 text-red-200 rounded p-2 mb-2">{{ inputFieldsError }}</div>
      <div v-if="mergedHeaders.length > 0" class="mb-2 text-[#b0bec5] text-xs">
        <!-- Merged Headers display removed as requested -->
      </div>
      <form v-if="selectedService && selectedMethod && ((reflectionInputFields.length > 0 && reflectionInputFields.some(f => !f.isRepeated || (f.isRepeated && requestData[f.name] && requestData[f.name].length > 0))) || allServices.find(svc => svc.name === selectedService)?.methods.find(m => m.name === selectedMethod)?.inputType?.fields?.length)" @submit.prevent>
        <div v-for="field in (reflectionInputFields.length > 0 ? reflectionInputFields : allServices.find(svc => svc.name === selectedService)?.methods.find(m => m.name === selectedMethod)?.inputType.fields || [])" :key="field.name" class="mb-3">
          <div class="flex items-center justify-between mb-1">
            <label class="block text-white font-semibold">{{ field.name }} <span class="text-[#42b983]">({{ field.type }}<span v-if="field.isRepeated">[]</span>)</span></label>
            <button v-if="field.isRepeated" type="button" class="text-[#42b983] hover:text-[#369870] flex items-center justify-center rounded-full w-5 h-5" style="border: none; background: none; padding: 0;" @click="addRepeatedField(field.name)">
              <span aria-label="Add" title="Add"><svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" fill="currentColor" viewBox="0 0 20 20"><circle cx="10" cy="10" r="8" stroke="#42b983" stroke-width="2" fill="none"/><line x1="10" y1="6" x2="10" y2="14" stroke="#42b983" stroke-width="2"/><line x1="6" y1="10" x2="14" y2="10" stroke="#42b983" stroke-width="2"/></svg></span>
            </button>
            <button v-if="field.type === 'message' && field.fields && field.fields.length > 0 && (!requestData[field.name] || !topLevelMessageExpanded[field.name])" type="button" class="text-[#42b983] hover:text-[#369870] flex items-center justify-center rounded-full w-5 h-5" style="border: none; background: none; padding: 0;" @click="toggleTopLevelMessageField(field.name)">
              <span aria-label="Expand" title="Expand"><svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" fill="currentColor" viewBox="0 0 20 20"><circle cx="10" cy="10" r="8" stroke="#42b983" stroke-width="2" fill="none"/><line x1="10" y1="6" x2="10" y2="14" stroke="#42b983" stroke-width="2"/><line x1="6" y1="10" x2="14" y2="10" stroke="#42b983" stroke-width="2"/></svg></span>
            </button>
            <button v-if="field.type === 'message' && field.fields && field.fields.length > 0 && requestData[field.name] && topLevelMessageExpanded[field.name]" type="button" class="text-[#42b983] hover:text-[#369870] flex items-center justify-center rounded-full w-5 h-5" style="border: none; background: none; padding: 0;" @click="toggleTopLevelMessageField(field.name)">
              <span aria-label="Collapse" title="Collapse"><svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" fill="currentColor" viewBox="0 0 20 20"><circle cx="10" cy="10" r="8" stroke="#42b983" stroke-width="2" fill="none"/><line x1="6" y1="10" x2="14" y2="10" stroke="#42b983" stroke-width="2"/></svg></span>
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
                <ProtoMessageField
                  v-else-if="field.type === 'message' && field.fields && field.fields.length > 0"
                  :fields="field.fields"
                  v-model="requestData[field.name]"
                  :fieldPath="field.name + '.'"
                />
                <span v-else-if="field.type === 'group'" class="italic text-[#b0bec5]">Group fields are not supported (legacy protobuf feature).</span>
                <span v-else-if="field.type !== 'message'" class="italic text-[#b0bec5]">Unsupported type: {{ field.type }}</span>
                <!-- For message fields, only show unsupported if not expandable (no subfields) -->
                <span v-else-if="field.type === 'message' && (!field.fields || field.fields.length === 0)" class="italic text-[#b0bec5]">Unsupported type: message</span>
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
            <div v-else-if="field.type === 'bool'" class="flex items-center gap-2 text-[0.8rem] text-[#b0bec5]">
              <input type="checkbox" :id="'bool-' + field.name" v-model="requestData[field.name]" class="text-[0.8rem] p-0 m-0" />
              <label :for="'bool-' + field.name" class="select-none text-[#b0bec5]">{{ field.name }}</label>
            </div>
            <input
              v-else-if="field.type === 'bytes'"
              type="text"
              class="w-full px-2 py-1 rounded bg-[#232b36] border border-[#2c3e50] text-white focus:outline-none text-[0.8rem]"
              v-model="requestData[field.name]"
              :placeholder="'base64 string'"
              :autocomplete="'off'"
              :autocorrect="'off'"
            />
            <template v-else-if="field.type === 'message' && field.fields && field.fields.length > 0 && topLevelMessageExpanded[field.name]">
              <ProtoMessageField
                :fields="field.fields"
                v-model="requestData[field.name]"
                :fieldPath="field.name + '.'"
              />
            </template>
            <span v-else-if="field.type === 'group'" class="italic text-[#b0bec5]">Group fields are not supported (legacy protobuf feature).</span>
            <span v-else-if="field.type !== 'message'" class="italic text-[#b0bec5]">Unsupported type: {{ field.type }}</span>
            <!-- For message fields, only show unsupported if not expandable (no subfields) -->
            <span v-else-if="field.type === 'message' && (!field.fields || field.fields.length === 0)" class="italic text-[#b0bec5]">Unsupported type: message</span>
          </template>
        </div>
      </form>
      <div v-else-if="selectedService && selectedMethod && !inputFieldsLoading && !inputFieldsError && ((reflectionInputFields.length === 0 && (!allServices.find(svc => svc.name === selectedService)?.methods.find(m => m.name === selectedMethod)?.inputType?.fields?.length)))" class="text-[#b0bec5] mt-2">
        This method does not require any input fields.
      </div>
      <!-- Per-request headers modal -->
      <div v-if="showHeadersModal" class="fixed inset-0 bg-black bg-opacity-40 flex items-center justify-center z-50">
        <div class="bg-white text-[#222] rounded-lg shadow-lg p-6 w-full max-w-lg text-[0.8rem] relative">
          <button class="absolute top-2 right-4 text-xl text-gray-400 hover:text-gray-700 font-bold" @click="showHeadersModal = false">&times;</button>
          <h3 class="text-lg font-bold mb-4">Edit Per-Request Headers</h3>
          <label class="font-semibold mb-2 block">Array of headers in JSON format</label>
          <textarea
            v-model="perRequestHeadersJson"
            class="w-full px-2 py-1 rounded border border-[#2c3e50] text-[0.8rem] font-mono"
            style="height: 120px; resize: none; font-size: 0.8rem; line-height: 1.2;"
            autocomplete="off"
            spellcheck="false"
            placeholder='[\n  { "Authorization": "token" }\n]'
          ></textarea>
          <div v-if="perRequestHeadersError" class="text-red-500 text-xs mt-1">{{ perRequestHeadersError }}</div>
          <div class="flex gap-2 mt-4">
            <button class="bg-[#42b983] text-white rounded px-3 py-1 font-bold hover:bg-[#369870] transition" @click="savePerRequestHeaders">Save</button>
            <button class="bg-gray-200 text-[#222] rounded px-3 py-1 font-bold hover:bg-gray-300 transition" @click="resetHeadersToServerDefault">Reset to server's default</button>
            <button class="bg-gray-200 text-[#222] rounded px-3 py-1 font-bold hover:bg-gray-300 transition" @click="showHeadersModal = false">Cancel</button>
          </div>
        </div>
      </div>
      <!-- Preview request modal -->
      <PreviewModal
        :show="showPreviewModal"
        :previewGrpcurlCommand="previewGrpcurlCommand"
        @close="showPreviewModal = false"
      />
    </section>
    <!-- Right column: Response Viewer -->
    <ResponseViewer
      :sendError="sendError"
      :formattedResponse="formattedResponse"
      :loading="sendLoading"
    />
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
.scrollable-column {
  min-height: 0;
  flex: 1 1 0%;
  overflow-y: auto;
  scrollbar-width: thin;
  scrollbar-color: #42b983 #232b36;
}
.scrollable-column::-webkit-scrollbar {
  width: 8px;
}
.scrollable-column::-webkit-scrollbar-thumb {
  background: #42b983;
  border-radius: 4px;
}
.scrollable-column::-webkit-scrollbar-track {
  background: #232b36;
}
</style>

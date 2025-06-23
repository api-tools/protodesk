<script setup lang="ts">
import ServerTopBar from '@/components/ServerTopBar.vue'
import { ref, onMounted, computed, watch, onUnmounted } from 'vue'
import { Greet, ListProtoDefinitionsByProfile, ListServerServices, ConnectToServer, GetMethodInputDescriptor, SavePerRequestHeaders, GetPerRequestHeaders, CallGRPCMethod } from '@wailsjs/go/app/App'
import { useServerProfileStore } from '@/stores/serverProfile'
import ProtoMessageField from '@/components/ProtoMessageField.vue'
import PreviewModal from '@/components/PreviewModal.vue'
import ServiceMethodTree from '@/components/ServiceMethodTree.vue'
import RequestBuilder from '@/components/RequestBuilder.vue'
import HeadersModal from '@/components/HeadersModal.vue'
import ResponseViewer from '@/components/ResponseViewer.vue'

// Server profile form and state
const profileStore = useServerProfileStore()
const newProfile = ref({ name: '', host: '', port: 50051, tlsEnabled: false, certificatePath: '' })
const editingProfileId = ref<string | null>(null)
const editProfileData = ref({ name: '', host: '', port: 50051, tlsEnabled: false, certificatePath: '' })

// Service/method tree state
const protoDefinitions = ref<any[]>([])
const selectedProtoFileId = ref<string | null>(null)
const services = computed(() => {
  const def = protoDefinitions.value.find(d => d.id === selectedProtoFileId.value)
  return def ? (def.services || []) : []
})
const selectedService = ref<string | null>(null)
const selectedMethod = ref<string | null>(null)
const activeProfile = computed(() => profileStore.activeProfile)
const reflectionServices = ref<{ [service: string]: string[] } | null>(null)
const reflectionError = ref<string | null>(null)
const connectionLoading = ref(false)
const connectionError = ref<string | null>(null)
const reflectionInputFields = ref<any[]>([])
const inputFieldsLoading = ref(false)
let isUnmounted = false;
onUnmounted(() => { isUnmounted = true; });
const inputFieldsError = ref<string | null>(null)
const perRequestHeadersJson = ref('')
const perRequestHeaders = ref<{ key: string, value: string }[]>([])
const perRequestHeadersError = ref('')
const showHeadersModal = ref(false)
const showPreviewModal = ref(false)
const serverHeaders = computed(() => (activeProfile.value && Array.isArray(activeProfile.value.headers)) ? activeProfile.value.headers : [])
const mergedHeaders = computed(() => perRequestHeaders.value.length > 0 ? perRequestHeaders.value : serverHeaders.value)
const expandedServices = ref<Record<string, boolean>>({})
const requestData = ref<Record<string, any>>({})
const responseData = ref<any>(null)
const sendLoading = ref(false)
const sendError = ref<string | null>(null)
const responseTime = ref<number | null>(null)
const responseSize = ref<number | null>(null)
const topLevelMessageExpanded = ref<Record<string, boolean>>({})
const methodSearch = ref('')
const leftWidth = ref(33.33)
const middleWidth = ref(33.33)
const rightWidth = ref(33.33)
let dragging = null as null | 'left' | 'right'
let startX = 0
let startLeft = 0
let startMiddle = 0
let startRight = 0
const previewGrpcurlCommand = computed(() => {
  if (!activeProfile.value || !selectedService.value || !selectedMethod.value) return ''
  const address = `${activeProfile.value.host}:${activeProfile.value.port}`
  // Convert array of {key, value} to object
  const headersArray = mergedHeaders.value
  const headersObj = Array.isArray(headersArray)
    ? Object.fromEntries(headersArray.map(h => [h.key, h.value]))
    : headersArray
  const headerFlags = Object.entries(headersObj)
    .map(([k, v]) => `-H '${k}: ${v}'`)
    .join(' ')
  // Use the same fixRequestDataForProto logic for preview
  const fields = reflectionInputFields.value.length > 0
    ? reflectionInputFields.value
    : (allServices.value.find(svc => svc.name === selectedService.value)?.methods.find(m => m.name === selectedMethod.value)?.inputType.fields || [])
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

// --- Add allServices computed property ---
const allServices = computed(() => {
  if (reflectionServices.value) {
    console.log('Building services from reflection:', reflectionServices.value)
    // Reflection: build [{ name, methods: [{ name }] }]
    const services = Object.entries(reflectionServices.value).map(([svc, methods]) => ({
      name: svc,
      methods: methods.map(m => ({ name: m }))
    }))
    console.log('Built services:', services)
    return services
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

// Filtered services for search
const filteredServices = computed(() => {
  if (!methodSearch.value.trim()) return allServices.value
  const search = methodSearch.value.trim().toLowerCase()
  const expanded: Record<string, boolean> = {}
  const filtered = allServices.value
    .map(service => {
      const matchingMethods = service.methods.filter((m: any) => m.name.toLowerCase().includes(search))
      if (matchingMethods.length > 0) {
        expanded[service.name] = true
        return { ...service, methods: matchingMethods }
      }
      return null
    })
    .filter((svc: any) => !!svc)
  // Expand all matching services
  if (Object.keys(expanded).length > 0) {
    for (const key in expanded) {
      expandedServices.value[key] = true
    }
  }
  return filtered
})

// --- Add event handlers for ServiceMethodTree ---
function toggleService(serviceName: string) {
  expandedServices.value[serviceName] = !expandedServices.value[serviceName]
}

// Add Field type for requestData initialization
interface Field {
  name: string
  type: string
  isRepeated?: boolean
  fields?: Field[]
}

function initializeRequestData(fields: Field[]): Record<string, any> {
  const data: Record<string, any> = {};
  for (const field of fields) {
    if (field.type === 'bool') {
      data[field.name] = false;
    } else if (field.isRepeated) {
      data[field.name] = [];
    } else {
      data[field.name] = null;
    }
  }
  return data;
}

// Add new refs for loading states
const servicesLoading = ref(false)
const requestBuilderLoading = ref(false)
const responseLoading = ref(false)

// Add function to clear all states
function clearAllStates() {
  selectedService.value = null
  selectedMethod.value = null
  reflectionServices.value = null
  protoDefinitions.value = []
  reflectionError.value = null
  connectionError.value = null
  requestData.value = {}
  responseData.value = null
  sendError.value = null
  responseTime.value = null
  responseSize.value = null
  expandedServices.value = {}
  topLevelMessageExpanded.value = {}
  reflectionInputFields.value = []
  perRequestHeaders.value = []
  perRequestHeadersJson.value = ''
}

// Modify fetchServicesAndMethods to handle loading states
async function fetchServicesAndMethods() {
  if (!activeProfile.value) {
    clearAllStates()
    connectionLoading.value = false
    servicesLoading.value = false
    return
  }

  // Clear previous states
  clearAllStates()
  
  if (activeProfile.value.useReflection) {
    connectionLoading.value = true
    servicesLoading.value = true
    connectionError.value = null
    try {
      console.log('Connecting to server:', activeProfile.value.id)
      await ConnectToServer(activeProfile.value.id)
      connectionLoading.value = false
      try {
        console.log('Fetching services via reflection')
        const result = await ListServerServices(activeProfile.value.id)
        console.log('Reflection services:', result)
        reflectionServices.value = result
        reflectionError.value = null
      } catch (e) {
        console.error('Reflection failed:', e)
        reflectionServices.value = null
        reflectionError.value = (typeof e === 'object' && e && 'message' in e) ? (e as any).message : String(e) || 'Reflection failed.'
      }
    } catch (e) {
      console.error('Connection failed:', e)
      connectionLoading.value = false
      connectionError.value = (typeof e === 'object' && e && 'message' in e) ? (e as any).message : String(e) || 'Failed to connect to server.'
      reflectionServices.value = null
      reflectionError.value = null
    } finally {
      servicesLoading.value = false
    }
  } else {
    servicesLoading.value = true
    await fetchProtoDefinitions()
    reflectionServices.value = null
    reflectionError.value = null
    connectionError.value = null
    connectionLoading.value = false
    servicesLoading.value = false
  }
}

// Modify selectMethod to handle loading states
async function selectMethod(serviceName: string, methodName: string) {
  selectedService.value = serviceName
  selectedMethod.value = methodName
  topLevelMessageExpanded.value = {}
  requestBuilderLoading.value = true
  let fields = []
  if (activeProfile.value && activeProfile.value.useReflection) {
    try {
      const descriptor = await GetMethodInputDescriptor(activeProfile.value.id, serviceName, methodName)
      if (Array.isArray(descriptor)) {
        fields = descriptor
      } else if (descriptor && typeof descriptor === 'object' && 'fields' in descriptor) {
        fields = (descriptor as any).fields || []
      }
    } catch (e) {
      fields = []
    }
  }
  // Fallback to proto definitions if not using reflection or fields is empty
  if (!fields.length) {
    const svc = allServices.value.find(svc => svc.name === serviceName)
    const method = svc?.methods.find(m => m.name === methodName)
    if (method && method.inputType && Array.isArray(method.inputType.fields)) {
      fields = method.inputType.fields
    }
  }
  reflectionInputFields.value = fields
  requestData.value = initializeRequestData(fields)
  requestBuilderLoading.value = false
}

// Utility to recursively omit null fields from an object
function omitNullFields(obj: any): any {
  if (Array.isArray(obj)) {
    return obj.map(omitNullFields);
  } else if (obj && typeof obj === 'object') {
    const result: any = {};
    for (const [key, value] of Object.entries(obj)) {
      if (value !== null) {
        result[key] = omitNullFields(value);
      }
    }
    return result;
  }
  return obj;
}

// Modify handleSend to handle loading states
async function handleSend() {
  sendLoading.value = true
  responseLoading.value = true
  sendError.value = ''
  responseData.value = null
  responseTime.value = null
  responseSize.value = null
  const startTime = performance.now()
  try {
    if (!activeProfile.value || !selectedService.value || !selectedMethod.value) {
      sendError.value = 'Missing profile, service, or method.'
      return
    }
    // Prepare request data
    const fields = (reflectionInputFields.value.length > 0
      ? reflectionInputFields.value
      : (allServices.value.find(svc => svc.name === selectedService.value)?.methods.find(m => m.name === selectedMethod.value)?.inputType.fields || []))
    const fixedRequestData = fixRequestDataForProto(requestData.value, fields)
    // Omit null fields before sending
    const cleanedRequestData = omitNullFields(fixedRequestData)
    let requestJSON = ''
    try {
      requestJSON = JSON.stringify(cleanedRequestData)
    } catch (e) {
      sendError.value = e instanceof Error ? 'Invalid request data: ' + e.message : 'Invalid request data: ' + String(e)
      return
    }
    // Merge headers and convert to object
    const merged = mergedHeaders.value
    const headersObj = Array.isArray(merged)
      ? Object.fromEntries(merged.map(h => [h.key, h.value]))
      : merged
    let headersJSON = ''
    try {
      headersJSON = JSON.stringify(headersObj)
    } catch (e) {
      sendError.value = e instanceof Error ? 'Invalid headers: ' + e.message : 'Invalid headers: ' + String(e)
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
    responseTime.value = Math.round(performance.now() - startTime)
    responseSize.value = new TextEncoder().encode(JSON.stringify(resp)).length
  } catch (e) {
    sendError.value = e instanceof Error ? e.message : String(e)
  } finally {
    sendLoading.value = false
    responseLoading.value = false
  }
}

function openHeadersModal() {}
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

watch(methodSearch, (val: string) => {
  if (!val.trim()) {
    for (const key in expandedServices.value) {
      expandedServices.value[key] = false
    }
  }
})

const fields = computed(() => {
  if (reflectionInputFields.value.length > 0) return reflectionInputFields.value
  const svc = allServices.value.find(svc => svc.name === selectedService.value)
  const method = svc?.methods.find(m => m.name === selectedMethod.value)
  return method?.inputType?.fields || []
})

function updatePerRequestHeadersJson(val: string) { perRequestHeadersJson.value = val }

watch([showHeadersModal, selectedService, selectedMethod, activeProfile], async ([show, svc, mth, profile]) => {
  if (show && svc && mth && profile) {
    try {
      const json = await GetPerRequestHeaders(profile.id, svc, mth);
      if (json && json.trim() !== '') {
        perRequestHeadersJson.value = json;
      } else if (serverHeaders.value.length > 0) {
        // Show server headers as default if no per-request headers
        perRequestHeadersJson.value = JSON.stringify(
          serverHeaders.value.map(h => ({ [h.key]: h.value })),
          null,
          2
        );
      } else {
        perRequestHeadersJson.value = '';
      }
      perRequestHeadersError.value = '';
    } catch {
      if (serverHeaders.value.length > 0) {
        perRequestHeadersJson.value = JSON.stringify(
          serverHeaders.value.map(h => ({ [h.key]: h.value })),
          null,
          2
        );
      } else {
        perRequestHeadersJson.value = '';
      }
      perRequestHeadersError.value = '';
    }
  }
});

function onPreviewUpdate(newCommand: string) {
  // Extract the -d '...' JSON from the command
  const match = newCommand.match(/-d\s+'([^']+)'/)
  if (!match) return
  try {
    const json = JSON.parse(match[1])
    requestData.value = json
  } catch {}
}

// Add back the missing functions
function fixRequestDataForProto(data: any, fields: any[]): any {
  const result: any = Array.isArray(data) ? [] : {};
  for (const field of fields) {
    const value = data[field.name];
    if (field.isRepeated && Array.isArray(value)) {
      result[field.name] = value.map((v: any) =>
        field.type === 'message' && field.fields
          ? fixRequestDataForProto(v, field.fields)
          : fixSingleFieldValue(v, field)
      );
    } else if (field.type === 'message' && field.fields) {
      result[field.name] = value ? fixRequestDataForProto(value, field.fields) : null;
    } else {
      result[field.name] = fixSingleFieldValue(value, field);
    }
  }
  return result;
}

function fixSingleFieldValue(value: any, field: any) {
  if ([
    'int32', 'int64', 'float', 'double', 'uint32', 'uint64',
    'fixed32', 'fixed64', 'sfixed32', 'sfixed64', 'sint32', 'sint64'
  ].includes(field.type)) {
    return value === '' ? null : value;
  }
  return value;
}

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

function toggleTopLevelMessageField(name: string) {
  topLevelMessageExpanded.value[name] = !topLevelMessageExpanded.value[name]
}

function onDragStart(which: 'left' | 'right', e: MouseEvent) {
  dragging = which
  startX = e.clientX
  startLeft = leftWidth.value
  startMiddle = middleWidth.value
  startRight = rightWidth.value
  document.body.style.cursor = 'col-resize'
  e.preventDefault()
}

function onDrag(e: MouseEvent) {
  if (!dragging) return
  const dx = e.clientX - startX
  if (dragging === 'left') {
    let newLeft = startLeft + (dx / window.innerWidth) * 100
    let newMiddle = startMiddle - (dx / window.innerWidth) * 100
    if (newLeft < 10) { newLeft = 10; newMiddle = startLeft + startMiddle - 10 }
    if (newMiddle < 10) { newMiddle = 10; newLeft = startLeft + startMiddle - 10 }
    leftWidth.value = newLeft
    middleWidth.value = newMiddle
  } else if (dragging === 'right') {
    let newMiddle = startMiddle + (dx / window.innerWidth) * 100
    let newRight = startRight - (dx / window.innerWidth) * 100
    if (newMiddle < 10) { newMiddle = 10; newRight = startMiddle + startRight - 10 }
    if (newRight < 10) { newRight = 10; newMiddle = startMiddle + startRight - 10 }
    middleWidth.value = newMiddle
    rightWidth.value = newRight
  }
}

function onDragEnd() {
  dragging = null
  document.body.style.cursor = ''
}

onMounted(() => {
  profileStore.loadProfiles()
  window.addEventListener('mousemove', onDrag)
  window.addEventListener('mouseup', onDragEnd)
})

onUnmounted(() => {
  window.removeEventListener('mousemove', onDrag)
  window.removeEventListener('mouseup', onDragEnd)
})

// Add back the watcher
watch(activeProfile, fetchServicesAndMethods, { immediate: true })
</script>

<template>
  <div id="app" class="app flex flex-col min-h-screen h-screen w-full">
    <ServerTopBar />
    <!-- Main Columns Row (fills available space above the status bar) -->
    <div style="flex: 1 1 0; min-height: 0; display: flex; flex-direction: row; width: 100vw; overflow: hidden;">
      <!-- Left column: Service/Method Tree -->
      <div :style="{ width: leftWidth + '%', boxSizing: 'border-box', borderRight: '1px solid #2c3e50', background: '#202733', padding: '16px', height: '100%', overflow: 'auto' }">
        <ServiceMethodTree
          :services="filteredServices"
          :expandedServices="expandedServices"
          :selectedService="selectedService ?? undefined"
          :selectedMethod="selectedMethod ?? undefined"
          :connectionLoading="connectionLoading"
          :servicesLoading="servicesLoading"
          :connectionError="connectionError ?? undefined"
          :reflectionError="reflectionError ?? undefined"
          v-model:methodSearch="methodSearch"
          @toggleService="toggleService"
          @selectMethod="selectMethod"
        />
      </div>
      <div class="resize-handle" @mousedown="e => onDragStart('left', e)"></div>
      <!-- Middle column: Request Builder -->
      <div :style="{ width: middleWidth + '%', boxSizing: 'border-box', borderRight: '1px solid #2c3e50', background: '#232b36', height: '100%', overflow: 'auto' }">
        <RequestBuilder
          :fields="fields"
          :requestData="requestData"
          :inputFieldsLoading="inputFieldsLoading || requestBuilderLoading"
          :inputFieldsError="inputFieldsError ?? undefined"
          :topLevelMessageExpanded="topLevelMessageExpanded"
          :selectedService="selectedService ?? undefined"
          :selectedMethod="selectedMethod ?? undefined"
          :mergedHeaders="mergedHeaders"
          :perRequestHeadersJson="perRequestHeadersJson"
          :perRequestHeadersError="perRequestHeadersError ?? undefined"
          :showHeadersModal="showHeadersModal"
          :showPreviewModal="showPreviewModal"
          :previewGrpcurlCommand="previewGrpcurlCommand"
          :sendLoading="sendLoading"
          :sendError="sendError ?? undefined"
          :reflectionInputFields="reflectionInputFields"
          :allServices="allServices"
          @addRepeatedField="addRepeatedField"
          @removeRepeatedField="removeRepeatedField"
          @toggleTopLevelMessageField="toggleTopLevelMessageField"
          @updateRequestData="val => requestData.value = val"
          @send="handleSend"
          @openHeadersModal="() => showHeadersModal = true"
          @savePerRequestHeaders="savePerRequestHeaders"
          @resetHeadersToServerDefault="resetHeadersToServerDefault"
          @setShowPreviewModal="() => showPreviewModal = true"
          @setShowHeadersModal="val => showHeadersModal = val"
          @update:perRequestHeadersJson="updatePerRequestHeadersJson"
        />
      </div>
      <div class="resize-handle" @mousedown="e => onDragStart('right', e)"></div>
      <!-- Right column: Response -->
      <div :style="{ width: rightWidth + '%', boxSizing: 'border-box', background: '#232b36', height: '100%', overflow: 'hidden', display: 'flex', flexDirection: 'column' }">
        <ResponseViewer
          :responseData="responseData"
          :sendLoading="sendLoading"
          :responseLoading="responseLoading"
          :sendError="sendError ?? undefined"
          :selectedService="selectedService ?? undefined"
          :selectedMethod="selectedMethod ?? undefined"
          :responseTime="responseTime ?? undefined"
          :responseSize="responseSize ?? undefined"
        />
      </div>
    </div>
    <!-- Modals -->
    <PreviewModal
      :show="showPreviewModal"
      :previewGrpcurlCommand="previewGrpcurlCommand"
      @close="showPreviewModal = false"
      @update="onPreviewUpdate"
    />
    <HeadersModal
      v-if="showHeadersModal"
      :show="showHeadersModal"
      :perRequestHeadersJson="perRequestHeadersJson"
      :perRequestHeadersError="perRequestHeadersError"
      @update:perRequestHeadersJson="updatePerRequestHeadersJson"
      @save="savePerRequestHeaders"
      @reset="resetHeadersToServerDefault"
      @close="() => showHeadersModal = false"
    />
    <!-- App-wide Status Bar: Connection Status -->
    <div style="height: 32px; min-height: 32px; max-height: 32px; background: #1b222c; border-top: 1px solid #2c3e50; display: flex; align-items: center; padding-left: 24px; font-size: 0.85rem; flex-shrink: 0;">
      <template v-if="connectionLoading">
        <span style="color: #b0bec5;">Connecting to server...</span>
      </template>
      <template v-else-if="connectionError">
        <span style="color: #e3342f;">{{ connectionError }}</span>
      </template>
      <template v-else-if="reflectionError">
        <span style="color: #e3342f;">{{ reflectionError }}</span>
      </template>
      <template v-else-if="activeProfile">
        <span style="color: #42b983;">Connected: {{ activeProfile.name }}</span>
      </template>
      <template v-else>
        <span style="color: #b0bec5;">No server connected</span>
      </template>
    </div>
  </div>
</template>

<style>
.app {
  font-family: 'Nunito', sans-serif;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
  min-height: 100vh;
  height: 100vh;
  display: flex;
  flex-direction: column;
  font-size: 0.8rem;
}

main {
  flex: 1 1 0%;
  min-height: 0;
  display: flex;
  flex-direction: column;
}

/* Merge HomeView.vue styles here */
.column-header {
  min-height: 48px;
  max-height: 48px;
  height: 48px;
}
.resize-handle {
  width: 3px;
  min-width: 3px;
  max-width: 3px;
  background: #2c3e50;
  cursor: col-resize;
  transition: background 0.2s;
  z-index: 1;
  height: 100vh;
  position: relative;
  box-sizing: border-box;
}
.resize-handle:hover {
  background: #42b983;
}
</style>

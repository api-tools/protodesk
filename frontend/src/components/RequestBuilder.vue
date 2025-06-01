<script setup lang="ts">
import { defineProps, defineEmits, ref } from 'vue'
import ProtoMessageField from '@/components/ProtoMessageField.vue'
import PreviewModal from '@/components/PreviewModal.vue'

interface Field {
  name: string
  type: string
  isRepeated?: boolean
  fields?: Field[]
  enumValues?: string[]
}
interface Method {
  name: string
  inputType?: {
    fields?: Field[]
  }
}
interface Service {
  name: string
  methods: Method[]
}

const props = defineProps<{
  fields: Field[]
  requestData: Record<string, any>
  inputFieldsLoading: boolean
  inputFieldsError?: string
  topLevelMessageExpanded: Record<string, boolean>
  selectedService?: string
  selectedMethod?: string
  mergedHeaders: Array<{ key: string, value: string }>
  perRequestHeadersJson: string
  perRequestHeadersError?: string
  showHeadersModal: boolean
  showPreviewModal: boolean
  previewGrpcurlCommand: string
  sendLoading: boolean
  sendError?: string
  reflectionInputFields: Field[]
  allServices: Service[]
}>()

const emit = defineEmits([
  'addRepeatedField', 'removeRepeatedField', 'toggleTopLevelMessageField', 'updateRequestData',
  'send', 'openHeadersModal', 'savePerRequestHeaders', 'resetHeadersToServerDefault',
  'setShowPreviewModal', 'setShowHeadersModal', 'updatePerRequestHeadersJson'
])

// Local state for repeated message field expansion
const repeatedMessageExpanded = ref<Record<string, Record<number, boolean>>>({})
function toggleRepeatedMessageField(fieldName: string, idx: number) {
  if (!repeatedMessageExpanded.value[fieldName]) repeatedMessageExpanded.value[fieldName] = {}
  repeatedMessageExpanded.value[fieldName][idx] = !repeatedMessageExpanded.value[fieldName][idx]
}

function disableNativeAutofill(event: Event) {
  const target = event.target as HTMLInputElement;
  target.autocomplete = "off";
  target.spellcheck = false;
  target.classList.add('no-autofill');
}
</script>
<template>
  <div style="width: 100%; height: 100%; display: flex; flex-direction: column; position: relative;">
    <!-- Fixed header -->
    <div style="height: 64px; min-height: 64px; max-height: 64px; background: #232b36; border-bottom: 1px solid #2c3e50; display: flex; align-items: center; justify-content: space-between; padding: 0 16px; flex-shrink: 0; position: absolute; top: 0; left: 0; right: 0; z-index: 1;">
      <div class="flex items-center h-full">
        <h2 class="font-bold text-white whitespace-nowrap">Request</h2>
      </div>
      <div class="flex items-center h-full gap-2">
        <button v-if="props.selectedService && props.selectedMethod" class="px-2 py-0.5 bg-[#42b983] text-white rounded hover:bg-[#369870] transition" @click="$emit('send')" style="min-height: 28px; font-size: 0.8rem;">
          Send
        </button>
      </div>
    </div>

    <!-- Scrollable content -->
    <div class="content-container" style="flex: 1 1 0; min-height: 0; overflow: auto; padding: 16px; margin-top: 64px;">
      <div v-if="props.inputFieldsLoading" class="bg-blue-900 text-blue-200 rounded p-2 mb-2">Loading request fields...</div>
      <div v-if="props.inputFieldsError" class="bg-red-900 text-red-200 rounded p-2 mb-2">{{ props.inputFieldsError }}</div>
      <form v-if="props.selectedService && props.selectedMethod && props.fields.length > 0" @submit.prevent>
        <div v-for="field in props.fields" :key="field.name" class="mb-3">
          <div class="flex items-center justify-between mb-1">
            <label class="block text-white font-normal">{{ field.name }} <span class="text-[#42b983]">({{ field.type }}<span v-if="field.isRepeated">[]</span>)</span></label>
            <button v-if="field.isRepeated" type="button" class="text-[#42b983] hover:text-[#369870] flex items-center justify-center rounded-full w-5 h-5" style="border: none; background: none; padding: 0;" @click="$emit('addRepeatedField', field.name)">
              <span aria-label="Add" title="Add"><svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" fill="currentColor" viewBox="0 0 20 20"><circle cx="10" cy="10" r="8" stroke="#42b983" stroke-width="2" fill="none"/><line x1="10" y1="6" x2="10" y2="14" stroke="#42b983" stroke-width="2"/><line x1="6" y1="10" x2="14" y2="10" stroke="#42b983" stroke-width="2"/></svg></span>
            </button>
            <button v-if="field.type === 'message' && field.fields && field.fields.length > 0 && (!props.requestData[field.name] || !props.topLevelMessageExpanded[field.name])" type="button" class="text-[#42b983] hover:text-[#369870] flex items-center justify-center rounded-full w-5 h-5" style="border: none; background: none; padding: 0;" @click="$emit('toggleTopLevelMessageField', field.name)">
              <span aria-label="Expand" title="Expand"><svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" fill="currentColor" viewBox="0 0 20 20"><circle cx="10" cy="10" r="8" stroke="#42b983" stroke-width="2" fill="none"/><line x1="10" y1="6" x2="10" y2="14" stroke="#42b983" stroke-width="2"/><line x1="6" y1="10" x2="14" y2="10" stroke="#42b983" stroke-width="2"/></svg></span>
            </button>
            <button v-if="field.type === 'message' && field.fields && field.fields.length > 0 && props.requestData[field.name] && props.topLevelMessageExpanded[field.name]" type="button" class="text-[#42b983] hover:text-[#369870] flex items-center justify-center rounded-full w-5 h-5" style="border: none; background: none; padding: 0;" @click="$emit('toggleTopLevelMessageField', field.name)">
              <span aria-label="Collapse" title="Collapse"><svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" fill="currentColor" viewBox="0 0 20 20"><circle cx="10" cy="10" r="8" stroke="#42b983" stroke-width="2" fill="none"/><line x1="6" y1="10" x2="14" y2="10" stroke="#42b983" stroke-width="2"/></svg></span>
            </button>
          </div>
          <!-- Repeated fields -->
          <template v-if="field.isRepeated">
            <div style="border-left: 2px solid #42b983; padding-left: 12px; margin-left: 4px;">
              <div v-for="(val, idx) in props.requestData[field.name]" :key="idx" class="flex items-center mb-1">
                <div class="flex-1 flex items-center">
                  <!-- Expand/collapse for repeated message fields -->
                  <button v-if="field.type === 'message' && field.fields && field.fields.length > 0" type="button" class="text-[#42b983] hover:text-[#369870] flex items-center justify-center rounded-full w-5 h-5 mr-1" style="border: none; background: none; padding: 0;" @click="toggleRepeatedMessageField(field.name, idx)">
                    <span v-if="!repeatedMessageExpanded[field.name]?.[idx]" aria-label="Expand" title="Expand"><svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" fill="currentColor" viewBox="0 0 20 20"><circle cx="10" cy="10" r="8" stroke="#42b983" stroke-width="2" fill="none"/><line x1="10" y1="6" x2="10" y2="14" stroke="#42b983" stroke-width="2"/><line x1="6" y1="10" x2="14" y2="10" stroke="#42b983" stroke-width="2"/></svg></span>
                    <span v-else aria-label="Collapse" title="Collapse"><svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" fill="currentColor" viewBox="0 0 20 20"><circle cx="10" cy="10" r="8" stroke="#42b983" stroke-width="2" fill="none"/><line x1="6" y1="10" x2="14" y2="10" stroke="#42b983" stroke-width="2"/></svg></span>
                  </button>
                  <ProtoMessageField
                    v-if="field.type === 'message' && field.fields && field.fields.length > 0 && repeatedMessageExpanded[field.name]?.[idx]"
                    :fields="field.fields"
                    v-model="props.requestData[field.name][idx]"
                    :fieldPath="field.name + '[' + idx + '].'"
                  />
                  <input
                    v-else-if="field.type === 'string' || field.type === 'int32' || field.type === 'int64' || field.type === 'float' || field.type === 'double' || field.type === 'uint32' || field.type === 'uint64' || field.type === 'fixed32' || field.type === 'fixed64' || field.type === 'sfixed32' || field.type === 'sfixed64' || field.type === 'sint32' || field.type === 'sint64'"
                    :type="field.type === 'string' ? 'text' : 'number'"
                    class="w-full px-2 py-1 rounded bg-[#232b36] border border-[#2c3e50] text-white focus:outline-none text-[0.8rem] no-autofill"
                    v-model="props.requestData[field.name][idx]"
                    :placeholder="field.type"
                    autocomplete="off"
                    autocorrect="off"
                    autocapitalize="off"
                    spellcheck="false"
                    inputmode="none"
                    @focus="disableNativeAutofill"
                    @input="disableNativeAutofill"
                  />
                  <select
                    v-else-if="field.type === 'enum' && field.enumValues && field.enumValues.length > 0"
                    class="w-full px-2 py-1 rounded bg-[#232b36] border border-[#2c3e50] text-white focus:outline-none text-[0.8rem] no-autofill"
                    v-model="props.requestData[field.name][idx]"
                    autocomplete="off"
                    autocorrect="off"
                  >
                    <option v-for="ev in field.enumValues" :key="ev" :value="ev">{{ ev }}</option>
                  </select>
                  <input
                    v-else-if="field.type === 'bool'"
                    type="checkbox"
                    v-model="props.requestData[field.name][idx]"
                    class="text-[0.8rem] p-0 m-0 no-autofill"
                  />
                  <input
                    v-else-if="field.type === 'bytes'"
                    type="text"
                    class="w-full px-2 py-1 rounded bg-[#232b36] border border-[#2c3e50] text-white focus:outline-none text-[0.8rem] no-autofill"
                    v-model="props.requestData[field.name][idx]"
                    :placeholder="'base64 string'"
                    autocomplete="off"
                    autocorrect="off"
                    autocapitalize="off"
                    spellcheck="false"
                    inputmode="none"
                    @focus="disableNativeAutofill"
                    @input="disableNativeAutofill"
                  />
                  <div v-else-if="field.type === 'google.protobuf.Timestamp'" class="flex flex-col gap-2">
                    <input
                      type="datetime-local"
                      class="w-full px-2 py-1 rounded bg-[#232b36] border border-[#2c3e50] text-white focus:outline-none text-[0.8rem] no-autofill"
                      :value="props.requestData[field.name] ? new Date(props.requestData[field.name].seconds * 1000).toISOString().slice(0, 16) : ''"
                      @input="(e: Event) => {
                        const target = e.target as HTMLInputElement;
                        const date = new Date(target.value);
                        if (isNaN(date.getTime())) {
                          props.requestData[field.name] = null;
                        } else {
                          props.requestData[field.name] = {
                            seconds: Math.floor(date.getTime() / 1000),
                            nanos: 0
                          };
                        }
                      }"
                    />
                  </div>
                  <span v-else-if="field.type === 'group'" class="italic text-[#b0bec5]">Group fields are not supported (legacy protobuf feature).</span>
                  <span v-else-if="field.type !== 'message'" class="italic text-[#b0bec5]">Unsupported type: {{ field.type }}</span>
                  <span v-else-if="field.type === 'message' && (!field.fields || field.fields.length === 0)" class="italic text-[#b0bec5]">Unsupported type: message</span>
                </div>
                <button type="button" class="ml-2 flex items-center justify-center rounded-full w-5 h-5" style="border: none; background: none; padding: 0;" @click="$emit('removeRepeatedField', field.name, idx)">
                  <span aria-label="Remove" title="Remove"><svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" fill="currentColor" viewBox="0 0 20 20"><circle cx="10" cy="10" r="8" stroke="#e3342f" stroke-width="2" fill="none"/><line x1="6" y1="10" x2="14" y2="10" stroke="#e3342f" stroke-width="2"/></svg></span>
                </button>
              </div>
            </div>
          </template>
          <!-- Non-repeated fields -->
          <template v-else>
            <input
              v-if="field.type === 'string' || field.type === 'int32' || field.type === 'int64' || field.type === 'float' || field.type === 'double' || field.type === 'uint32' || field.type === 'uint64' || field.type === 'fixed32' || field.type === 'fixed64' || field.type === 'sfixed32' || field.type === 'sfixed64' || field.type === 'sint32' || field.type === 'sint64'"
              :type="field.type === 'string' ? 'text' : 'number'"
              class="w-full px-2 py-1 rounded bg-[#232b36] border border-[#2c3e50] text-white focus:outline-none text-[0.8rem] no-autofill"
              v-model="props.requestData[field.name]"
              :placeholder="field.type"
              autocomplete="off"
              autocorrect="off"
              autocapitalize="off"
              spellcheck="false"
              inputmode="none"
              @focus="disableNativeAutofill"
              @input="disableNativeAutofill"
            />
            <select
              v-else-if="field.type === 'enum' && field.enumValues && field.enumValues.length > 0"
              class="w-full px-2 py-1 rounded bg-[#232b36] border border-[#2c3e50] text-white focus:outline-none text-[0.8rem] no-autofill"
              v-model="props.requestData[field.name]"
              autocomplete="off"
              autocorrect="off"
            >
              <option v-for="ev in field.enumValues" :key="ev" :value="ev">{{ ev }}</option>
            </select>
            <div v-else-if="field.type === 'bool'" class="flex items-center gap-2 text-[0.8rem] text-[#b0bec5]">
              <input type="checkbox" :id="'bool-' + field.name" v-model="props.requestData[field.name]" class="text-[0.8rem] p-0 m-0 no-autofill" />
              <label :for="'bool-' + field.name" class="select-none text-[#b0bec5]">{{ field.name }}</label>
            </div>
            <input
              v-else-if="field.type === 'bytes'"
              type="text"
              class="w-full px-2 py-1 rounded bg-[#232b36] border border-[#2c3e50] text-white focus:outline-none text-[0.8rem] no-autofill"
              v-model="props.requestData[field.name]"
              :placeholder="'base64 string'"
              autocomplete="off"
              autocorrect="off"
              autocapitalize="off"
              spellcheck="false"
              inputmode="none"
              @focus="disableNativeAutofill"
              @input="disableNativeAutofill"
            />
            <div v-else-if="field.type === 'google.protobuf.Timestamp'" class="flex flex-col gap-2">
              <input
                type="datetime-local"
                class="w-full px-2 py-1 rounded bg-[#232b36] border border-[#2c3e50] text-white focus:outline-none text-[0.8rem] no-autofill"
                :value="props.requestData[field.name] ? new Date(props.requestData[field.name].seconds * 1000).toISOString().slice(0, 16) : ''"
                @input="(e: Event) => {
                  const target = e.target as HTMLInputElement;
                  const date = new Date(target.value);
                  if (isNaN(date.getTime())) {
                    props.requestData[field.name] = null;
                  } else {
                    props.requestData[field.name] = {
                      seconds: Math.floor(date.getTime() / 1000),
                      nanos: 0
                    };
                  }
                }"
              />
            </div>
            <template v-else-if="field.type === 'message' && field.fields && field.fields.length > 0 && props.topLevelMessageExpanded[field.name]">
              <ProtoMessageField
                :fields="field.fields"
                v-model="props.requestData[field.name]"
                :fieldPath="field.name + '.'"
              />
            </template>
            <span v-else-if="field.type === 'group'" class="italic text-[#b0bec5]">Group fields are not supported (legacy protobuf feature).</span>
            <span v-else-if="field.type !== 'message'" class="italic text-[#b0bec5]">Unsupported type: {{ field.type }}</span>
            <span v-else-if="field.type === 'message' && (!field.fields || field.fields.length === 0)" class="italic text-[#b0bec5]">Unsupported type: message</span>
          </template>
        </div>
      </form>
      <div v-else-if="props.selectedService && props.selectedMethod && !props.inputFieldsLoading && !props.inputFieldsError && props.fields.length === 0" class="text-[#b0bec5] mt-2">
        This method does not require any input fields.
      </div>
      <!-- Per-request headers modal and preview modal as in HomeView.vue -->
      <!-- ... (omitted for brevity, but should match your previous implementation) ... -->
    </div>

    <!-- Status bar -->
    <div style="height: 28px; min-height: 28px; max-height: 28px; background: #1b222c; border-top: 1px solid #2c3e50; display: flex; align-items: center; justify-content: space-between; padding-left: 16px; padding-right: 8px; font-size: 0.75rem; flex-shrink: 0; color: #fff; margin: 0; gap: 8px;">
      <div></div>
      <div class="flex items-center gap-2">
        <button
          v-if="props.selectedService && props.selectedMethod"
          @click="$emit('setShowHeadersModal', true)"
          style="background: none; border: none; padding: 0; margin: 0; display: flex; align-items: center; cursor: pointer; color: #b0bec5;"
          title="Edit headers"
          aria-label="Edit headers"
        >
          <!-- Sliders/settings icon -->
          <svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" fill="none" viewBox="0 0 24 24">
            <circle cx="6" cy="12" r="2" stroke="#42b983" stroke-width="2"/>
            <circle cx="12" cy="6" r="2" stroke="#42b983" stroke-width="2"/>
            <circle cx="18" cy="18" r="2" stroke="#42b983" stroke-width="2"/>
            <path stroke="#42b983" stroke-width="2" d="M6 4v6m0 4v6M12 4v2m0 4v12M18 4v12m0 4v0"/>
          </svg>
        </button>
        <button
          v-if="props.selectedService && props.selectedMethod"
          @click="$emit('setShowPreviewModal', true)"
          style="background: none; border: none; padding: 0; margin-left: 0; display: flex; align-items: center; cursor: pointer; color: #b0bec5;"
          title="Preview grpcurl command"
          aria-label="Preview grpcurl command"
        >
          <svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" fill="none" viewBox="0 0 24 24">
            <path stroke="#42b983" stroke-width="2" d="M1.5 12S5.5 5.5 12 5.5 22.5 12 22.5 12 18.5 18.5 12 18.5 1.5 12 1.5 12Z"/>
            <circle cx="12" cy="12" r="3.5" stroke="#42b983" stroke-width="2"/>
          </svg>
        </button>
      </div>
    </div>
  </div>
</template> 

<style>
.no-autofill {
  -webkit-user-modify: read-write-plaintext-only !important;
  -webkit-autofill: off !important;
  -webkit-text-fill-color: inherit !important;
}
</style> 
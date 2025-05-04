<script setup lang="ts">
import { computed, toRefs, watch, ref } from 'vue'

const props = defineProps<{
  fields: any[],
  modelValue: Record<string, any> | null,
  fieldPath?: string
}>()
const emit = defineEmits(['update:modelValue'])

const { fields, modelValue, fieldPath } = toRefs(props)

function updateField(name: string, value: any) {
  if (modelValue.value === null) return
  emit('update:modelValue', { ...modelValue.value, [name]: value })
}

function addRepeatedField(name: string) {
  if (modelValue.value === null) return
  const arr = Array.isArray(modelValue.value[name]) ? [...modelValue.value[name]] : []
  arr.push('')
  updateField(name, arr)
}
function removeRepeatedField(name: string, idx: number) {
  if (modelValue.value === null) return
  const arr = Array.isArray(modelValue.value[name]) ? [...modelValue.value[name]] : []
  arr.splice(idx, 1)
  updateField(name, arr)
}

function expandMessageField(name: string, subfields: any[]) {
  // Initialize as object with all subfields empty/null
  const obj: Record<string, any> = {}
  for (const f of subfields) {
    if (f.type === 'message') {
      obj[f.name] = null
    } else if (f.isRepeated) {
      obj[f.name] = []
    } else if (f.type === 'bool') {
      obj[f.name] = false
    } else {
      obj[f.name] = ''
    }
  }
  emit('update:modelValue', { ...modelValue.value, [name]: obj })
}
function collapseMessageField(name: string) {
  emit('update:modelValue', { ...modelValue.value, [name]: null })
}
</script>
<template>
  <div class="proto-message-fields relative">
    <div class="proto-message-vertical-line"></div>
    <div class="pl-4 proto-message-scrollable">
      <div v-for="field in fields" :key="(fieldPath || '') + field.name">
        <!-- Scalar and enum fields -->
        <template v-if="['string','int32','int64','float','double','uint32','uint64','fixed32','fixed64','sfixed32','sfixed64','sint32','sint64'].includes(field.type)">
          <label class="block text-white font-semibold mb-1">{{ field.name }} <span class="text-[#42b983]">({{ field.type }})</span></label>
          <input
            v-if="field.type === 'string'"
            type="text"
            class="w-full px-2 py-1 rounded bg-[#232b36] border border-[#2c3e50] text-white focus:outline-none text-[0.8rem] mb-2"
            :value="modelValue && modelValue[field.name]"
            @input="updateField(field.name, ($event.target && ($event.target as HTMLInputElement).value) || '')"
          />
          <input
            v-else
            type="number"
            class="w-full px-2 py-1 rounded bg-[#232b36] border border-[#2c3e50] text-white focus:outline-none text-[0.8rem] mb-2"
            :value="modelValue && modelValue[field.name]"
            @input="updateField(field.name, ($event.target && ($event.target as HTMLInputElement).value) || '')"
          />
        </template>
        <template v-else-if="field.type === 'bool'">
          <div class="flex items-center gap-2 text-[0.8rem] text-[#b0bec5] mb-2">
            <input type="checkbox" :id="'bool-' + (fieldPath || '') + field.name" :checked="modelValue && modelValue[field.name]" @change="updateField(field.name, $event.target && ($event.target as HTMLInputElement).checked)" class="text-[0.8rem] p-0 m-0" />
            <label :for="'bool-' + (fieldPath || '') + field.name" class="select-none text-[#b0bec5]">{{ field.name }}</label>
          </div>
        </template>
        <template v-else-if="field.type === 'enum' && field.enumValues && field.enumValues.length > 0">
          <label class="block text-white font-semibold mb-1">{{ field.name }} <span class="text-[#42b983]">(enum)</span></label>
          <select
            class="w-full px-2 py-1 rounded bg-[#232b36] border border-[#2c3e50] text-white focus:outline-none text-[0.8rem] mb-2"
            :value="modelValue && modelValue[field.name]"
            @change="updateField(field.name, ($event.target && ($event.target as HTMLSelectElement).value) || '')"
          >
            <option v-for="ev in field.enumValues" :key="ev" :value="ev">{{ ev }}</option>
          </select>
        </template>

        <!-- Repeated fields (with vertical line spanning the group, but NOT for repeated message fields) -->
        <template v-else-if="field.isRepeated && field.type !== 'message'">
          <div class="repeated-field-group mb-2">
            <div class="flex items-center mb-1">
              <label class="block text-white font-semibold">{{ field.name }} <span class="text-[#42b983]">({{ field.type }}[])</span></label>
              <button type="button" class="ml-2 flex items-center justify-center rounded-full w-5 h-5 bg-[#42b983] text-white" @click="addRepeatedField(field.name)">
                <svg width="14" height="14" viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg">
                  <circle cx="10" cy="10" r="8" stroke="white" stroke-width="2" fill="#42b983"/>
                  <line x1="10" y1="6" x2="10" y2="14" stroke="white" stroke-width="2"/>
                  <line x1="6" y1="10" x2="14" y2="10" stroke="white" stroke-width="2"/>
                </svg>
              </button>
            </div>
            <div class="repeated-field-vertical-line">
              <div v-for="(val, idx) in (modelValue && modelValue[field.name]) || []" :key="idx" class="flex items-center mb-1 repeated-field-entry">
                <input
                  v-if="field.type === 'string'"
                  type="text"
                  class="w-full px-2 py-1 rounded bg-[#232b36] border border-[#2c3e50] text-white focus:outline-none text-[0.8rem]"
                  :value="val"
                  @input="updateField(field.name, [...((modelValue && modelValue[field.name]) || []).slice(0, idx), ($event.target && ($event.target as HTMLInputElement).value) || '', ...((modelValue && modelValue[field.name]) || []).slice(idx + 1)])"
                />
                <input
                  v-else
                  type="number"
                  class="w-full px-2 py-1 rounded bg-[#232b36] border border-[#2c3e50] text-white focus:outline-none text-[0.8rem]"
                  :value="val"
                  @input="updateField(field.name, [...((modelValue && modelValue[field.name]) || []).slice(0, idx), ($event.target && ($event.target as HTMLInputElement).value) || '', ...((modelValue && modelValue[field.name]) || []).slice(idx + 1)])"
                />
                <button type="button" class="ml-2 flex items-center justify-center rounded-full w-5 h-5 bg-red-600 text-white" @click="removeRepeatedField(field.name, idx)">
                  &times;
                </button>
              </div>
            </div>
          </div>
        </template>
        <!-- Expandable/collapsible message fields (plus to the right of label, at all levels) -->
        <template v-else-if="field.type === 'message' && field.fields && field.fields.length > 0">
          <div class="mb-2">
            <div class="flex items-center mb-1">
              <label class="block text-white font-semibold flex-1">{{ field.name }} <span class="text-[#42b983]">(message)</span></label>
              <button v-if="!modelValue || modelValue[field.name] == null" type="button" class="ml-2 flex items-center justify-center rounded-full w-5 h-5 bg-[#42b983] text-white" @click="expandMessageField(field.name, field.fields)">
                <svg width="14" height="14" viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg">
                  <circle cx="10" cy="10" r="8" stroke="white" stroke-width="2" fill="#42b983"/>
                  <line x1="10" y1="6" x2="10" y2="14" stroke="white" stroke-width="2"/>
                  <line x1="6" y1="10" x2="14" y2="10" stroke="white" stroke-width="2"/>
                </svg>
              </button>
              <button v-else type="button" class="ml-2 flex items-center justify-center rounded-full w-5 h-5 bg-red-600 text-white" @click="collapseMessageField(field.name)">
                <span aria-label="Collapse" title="Collapse">&minus;</span>
              </button>
            </div>
            <div v-if="modelValue && modelValue[field.name] != null" class="proto-message-vertical-line-group">
              <ProtoMessageField
                :fields="field.fields"
                v-model="modelValue[field.name]"
                :fieldPath="(fieldPath || '') + field.name + '.'"
              />
            </div>
          </div>
        </template>
        <!-- Fallback for unsupported types -->
        <template v-else>
          <span class="italic text-[#b0bec5]">Unsupported field: {{ field.name }} ({{ field.type }})</span>
        </template>
      </div>
    </div>
  </div>
</template>

<style scoped>
.proto-message-fields {
  position: relative;
  margin-bottom: 1rem;
}
.proto-message-vertical-line {
  position: absolute;
  left: 0;
  top: 0;
  bottom: 0;
  width: 2px;
  background: #42b983;
  border-radius: 1px;
  z-index: 0;
}
.pl-4 {
  position: relative;
  z-index: 1;
}
/* Make the second column scrollable if content exceeds max height */
.proto-message-scrollable {
  max-height: 400px;
  overflow-y: auto;
  scrollbar-width: thin;
  scrollbar-color: #42b983 #232b36;
}
.proto-message-scrollable::-webkit-scrollbar {
  width: 8px;
}
.proto-message-scrollable::-webkit-scrollbar-thumb {
  background: #42b983;
  border-radius: 4px;
}
.proto-message-scrollable::-webkit-scrollbar-track {
  background: #232b36;
}
/* New: vertical line for repeated/message field groups */
.proto-message-vertical-line-group {
  position: relative;
  margin-left: 0.5rem;
  padding-left: 1rem;
}
.proto-message-vertical-line-group::before {
  content: '';
  position: absolute;
  left: 0;
  top: 0;
  bottom: 0;
  width: 2px;
  background: #42b983;
  border-radius: 1px;
  z-index: 0;
}
/* Repeated field group vertical line */
.repeated-field-group {
  position: relative;
  padding-left: 1.5rem;
}
.repeated-field-vertical-line {
  position: relative;
}
.repeated-field-vertical-line::before {
  content: '';
  position: absolute;
  left: -1.1rem;
  top: 0;
  bottom: 0;
  width: 2px;
  background: #42b983;
  border-radius: 1px;
  z-index: 0;
}
.repeated-field-entry {
  position: relative;
  z-index: 1;
}
</style> 
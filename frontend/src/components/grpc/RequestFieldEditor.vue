<script setup lang="ts">
import {Braces, Calendar, ListTree, Plus, Trash2} from '@lucide/vue'
import {computed, onBeforeUnmount, ref, watch} from 'vue'
import type {GrpcField, GrpcMessageType} from '../../types/grpc'
import UiButton from '../ui/UiButton.vue'
import UiIconButton from '../ui/UiIconButton.vue'

defineOptions({name: 'RequestFieldEditor'})

const props = withDefaults(defineProps<{
  field: GrpcField
  value: unknown
  messageTypes?: Record<string, GrpcMessageType>
  depth?: number
  ancestorTypes?: string[]
}>(), {
  messageTypes: () => ({}),
  depth: 0,
  ancestorTypes: () => [],
})

const emit = defineEmits<{
  'update:value': [value: unknown]
}>()

const maxStructuredDepth = 6
const jsonDraft = ref(formatJsonValue(props.value))
const jsonError = ref('')
const messageMode = ref<'form' | 'json'>(canUseStructuredMessage() ? 'form' : 'json')
const timestampDateCombo = ref<HTMLElement | null>(null)
const timestampCalendarPopover = ref<HTMLElement | null>(null)
const timestampCalendarOpen = ref(false)
const timestampCalendarMonth = ref(startOfUTCMonth(timestampDate() ?? new Date()))
const timestampCalendarStyle = ref<Record<string, string>>({})

watch(() => props.value, (value) => {
  if (!jsonError.value) jsonDraft.value = formatJsonValue(value)
})

watch(() => props.field.messageType, () => {
  jsonError.value = ''
  jsonDraft.value = formatJsonValue(props.value)
  messageMode.value = canUseStructuredMessage() ? 'form' : 'json'
})

const arrayValue = computed(() => Array.isArray(props.value) ? props.value : [])
const itemField = computed<GrpcField>(() => ({...props.field, repeated: false}))
const messageFields = computed(() => props.field.messageType ? props.messageTypes[props.field.messageType]?.fields : undefined)
const nextAncestorTypes = computed(() => props.field.messageType
  ? [...props.ancestorTypes, props.field.messageType]
  : props.ancestorTypes)
const timestampCalendarTitle = computed(() => timestampCalendarMonth.value.toLocaleDateString(undefined, {
  month: 'long',
  year: 'numeric',
  timeZone: 'UTC',
}))
const timestampCalendarDays = computed(() => {
  const year = timestampCalendarMonth.value.getUTCFullYear()
  const month = timestampCalendarMonth.value.getUTCMonth()
  const leadingBlanks = timestampCalendarMonth.value.getUTCDay()
  const daysInMonth = new Date(Date.UTC(year, month + 1, 0)).getUTCDate()
  return [
    ...Array.from({length: leadingBlanks}, () => null),
    ...Array.from({length: daysInMonth}, (_, index) => {
      const day = index + 1
      const date = new Date(Date.UTC(year, month, day))
      return {
        day,
        value: date.toISOString().slice(0, 10),
        label: date.toLocaleDateString(undefined, {
          day: 'numeric',
          month: 'long',
          year: 'numeric',
          timeZone: 'UTC',
        }),
      }
    }),
  ]
})

function canUseStructuredMessage(): boolean {
  const messageType = props.field.messageType
  return Boolean(
    messageType
    && !isWellKnownJsonMessage(messageType)
    && props.messageTypes[messageType]
    && props.depth < maxStructuredDepth
    && !props.ancestorTypes.includes(messageType),
  )
}

function addArrayItem() {
  emit('update:value', [...arrayValue.value, defaultValue(itemField.value)])
}

function updateArrayItem(index: number, value: unknown) {
  const next = [...arrayValue.value]
  next[index] = value
  emit('update:value', next)
}

function removeArrayItem(index: number) {
  emit('update:value', arrayValue.value.filter((_, itemIndex) => itemIndex !== index))
}

function updateNestedField(field: GrpcField, value: unknown) {
  const current = isJsonObject(props.value) ? {...props.value} : {}
  const fieldName = field.jsonName || field.name
  if (value === undefined || value === null || value === '') {
    delete current[fieldName]
  } else {
    current[fieldName] = value
  }
  emit('update:value', current)
}

function updateScalar(rawValue: string) {
  if (rawValue === '') {
    emit('update:value', undefined)
    return
  }
  emit('update:value', usesNumberInput(props.field) ? Number(rawValue) : rawValue)
}

function updateJson(rawValue: string) {
  jsonDraft.value = rawValue
  if (!rawValue.trim()) {
    jsonError.value = ''
    emit('update:value', undefined)
    return
  }
  try {
    const parsed = JSON.parse(rawValue)
    if (!isJsonObject(parsed)) throw new Error('Value must be a JSON object.')
    jsonError.value = ''
    emit('update:value', parsed)
  } catch (error) {
    jsonError.value = error instanceof Error ? error.message : 'Invalid JSON object.'
  }
}

function setMessageMode(mode: 'form' | 'json') {
  if (mode === 'form' && !canUseStructuredMessage()) return
  jsonError.value = ''
  jsonDraft.value = formatJsonValue(props.value)
  messageMode.value = mode
}

function updateTimestampDate(rawDate: string) {
  const normalizedDate = normalizeTimestampDateInput(rawDate)
  if (!rawDate.trim()) {
    emit('update:value', undefined)
    return
  }
  if (normalizedDate) updateTimestamp(normalizedDate, timestampHourValue())
}

function openTimestampCalendar() {
  if (timestampCalendarOpen.value) {
    closeTimestampCalendar()
    return
  }
  timestampCalendarMonth.value = startOfUTCMonth(timestampDate() ?? new Date())
  const rect = timestampDateCombo.value?.getBoundingClientRect()
  if (rect) {
    const width = 244
    const estimatedHeight = 292
    const left = Math.min(Math.max(rect.left, 8), window.innerWidth - width - 8)
    const below = rect.bottom + 6
    const top = below + estimatedHeight <= window.innerHeight
      ? below
      : Math.max(8, rect.top - estimatedHeight - 6)
    timestampCalendarStyle.value = {left: `${left}px`, top: `${top}px`}
  }
  timestampCalendarOpen.value = true
  document.addEventListener('pointerdown', closeCalendarOnOutsidePointerDown, true)
  document.addEventListener('keydown', closeCalendarOnEscape)
}

function closeTimestampCalendar() {
  timestampCalendarOpen.value = false
  document.removeEventListener('pointerdown', closeCalendarOnOutsidePointerDown, true)
  document.removeEventListener('keydown', closeCalendarOnEscape)
}

function closeCalendarOnOutsidePointerDown(event: PointerEvent) {
  const target = event.target as Node
  if (
    !timestampDateCombo.value?.contains(target)
    && !timestampCalendarPopover.value?.contains(target)
  ) closeTimestampCalendar()
}

function closeCalendarOnEscape(event: KeyboardEvent) {
  if (event.key === 'Escape') closeTimestampCalendar()
}

function changeTimestampCalendarMonth(offset: number) {
  timestampCalendarMonth.value = new Date(Date.UTC(
    timestampCalendarMonth.value.getUTCFullYear(),
    timestampCalendarMonth.value.getUTCMonth() + offset,
    1,
  ))
}

function selectTimestampCalendarDate(date: string) {
  updateTimestamp(date, timestampHourValue())
  closeTimestampCalendar()
}

function startOfUTCMonth(date: Date): Date {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), 1))
}

onBeforeUnmount(closeTimestampCalendar)

function updateTimestampHour(rawHour: string) {
  const date = normalizeTimestampDateInput(timestampDateValue()) || new Date().toISOString().slice(0, 10)
  updateTimestamp(date, Number(rawHour))
}

function updateTimestamp(date: string, hour: number) {
  const normalizedHour = Math.min(Math.max(Number.isFinite(hour) ? hour : 0, 0), 23)
  emit('update:value', `${date}T${String(normalizedHour).padStart(2, '0')}:00:00Z`)
}

function timestampDateValue(): string {
  const date = timestampDate()
  return date ? date.toISOString().slice(0, 10).replaceAll('-', '/') : ''
}

function timestampNativeDateValue(): string {
  const date = timestampDate()
  return date ? date.toISOString().slice(0, 10) : ''
}

function timestampHourValue(): number {
  return timestampDate()?.getUTCHours() ?? 0
}

function timestampDate(): Date | null {
  if (typeof props.value !== 'string') return null
  const date = new Date(props.value)
  return Number.isNaN(date.getTime()) ? null : date
}

function normalizeTimestampDateInput(value: string): string {
  const match = value.trim().match(/^(\d{4})[/-](\d{2})[/-](\d{2})$/)
  return match ? `${match[1]}-${match[2]}-${match[3]}` : ''
}

function defaultValue(field: GrpcField): unknown {
  if (isTimestampField(field)) return new Date().toISOString()
  if (wrapperScalarType(field) === 'bool' || field.type === 'bool') return false
  if (wrapperScalarType(field) === 'number' || usesNumberInput(field)) return 0
  if (field.enumValues?.length) return field.enumValues[0]
  if (isMessageField(field)) return {}
  return ''
}

function isTimestampField(field: GrpcField): boolean {
  return field.messageType === 'google.protobuf.Timestamp' || field.messageType?.endsWith('.Timestamp') === true
}

function isMessageField(field: GrpcField): boolean {
  return field.type === 'message' || Boolean(field.messageType)
}

function isWellKnownJsonMessage(messageType: string): boolean {
  return messageType === 'google.protobuf.Struct'
    || messageType === 'google.protobuf.Value'
    || messageType === 'google.protobuf.ListValue'
    || messageType === 'google.protobuf.Duration'
}

function wrapperScalarType(field: GrpcField): 'string' | 'number' | 'bool' | null {
  const name = field.messageType?.split('.').pop()
  if (!name?.endsWith('Value')) return null
  if (name === 'BoolValue') return 'bool'
  if (['DoubleValue', 'FloatValue', 'Int32Value', 'UInt32Value'].includes(name)) return 'number'
  if (['StringValue', 'BytesValue', 'Int64Value', 'UInt64Value'].includes(name)) return 'string'
  return null
}

function usesNumberInput(field: GrpcField): boolean {
  return wrapperScalarType(field) === 'number'
    || ['double', 'float', 'int32', 'uint32', 'sint32', 'fixed32', 'sfixed32'].includes(field.type)
}

function usesBooleanInput(field: GrpcField): boolean {
  return wrapperScalarType(field) === 'bool' || field.type === 'bool'
}

function isJsonObject(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value)
}

function formatJsonValue(value: unknown): string {
  return JSON.stringify(isJsonObject(value) ? value : {}, null, 2)
}
</script>

<template>
  <div v-if="field.repeated" class="repeated-field-editor">
    <div v-if="arrayValue.length === 0" class="repeated-field-empty">No items.</div>
    <div v-for="(item, index) in arrayValue" :key="index" class="repeated-field-item">
      <span class="repeated-field-index">{{ index }}</span>
      <div class="repeated-field-value">
        <RequestFieldEditor
          :field="itemField"
          :value="item"
          :message-types="messageTypes"
          :depth="depth + 1"
          :ancestor-types="ancestorTypes"
          @update:value="updateArrayItem(index, $event)"
        />
      </div>
      <UiIconButton :label="`Remove item ${index + 1}`" variant="ghost" @click="removeArrayItem(index)">
        <Trash2 :size="14" aria-hidden="true" />
      </UiIconButton>
    </div>
    <UiButton class="repeated-field-add" variant="secondary" @click="addArrayItem">
      <template #icon><Plus :size="14" aria-hidden="true" /></template>
      Add item
    </UiButton>
  </div>

  <div v-else-if="isTimestampField(field)" class="timestamp-field-control">
    <div class="timestamp-picker-row">
      <div ref="timestampDateCombo" class="timestamp-date-combo">
        <input
          class="request-field-input"
          :value="timestampDateValue()"
          type="text"
          placeholder="yyyy/mm/dd"
          aria-label="Timestamp date"
          @input="updateTimestampDate(($event.target as HTMLInputElement).value)"
        >
        <button
          class="timestamp-calendar-button"
          type="button"
          aria-label="Open timestamp calendar"
          :aria-expanded="timestampCalendarOpen"
          @click="openTimestampCalendar"
        >
          <Calendar :size="14" aria-hidden="true" />
        </button>
        <Teleport to="body">
          <div
            v-if="timestampCalendarOpen"
            ref="timestampCalendarPopover"
            class="timestamp-calendar-popover"
            :style="timestampCalendarStyle"
            role="dialog"
            aria-label="Choose timestamp date"
          >
            <div class="timestamp-calendar-header">
              <button type="button" aria-label="Previous month" @click="changeTimestampCalendarMonth(-1)">‹</button>
              <strong>{{ timestampCalendarTitle }}</strong>
              <button type="button" aria-label="Next month" @click="changeTimestampCalendarMonth(1)">›</button>
            </div>
            <div class="timestamp-calendar-weekdays" aria-hidden="true">
              <span v-for="(weekday, index) in ['S', 'M', 'T', 'W', 'T', 'F', 'S']" :key="index">{{ weekday }}</span>
            </div>
            <div class="timestamp-calendar-grid">
              <span v-for="(_, index) in timestampCalendarDays.filter(day => day === null)" :key="`blank-${index}`"></span>
              <button
                v-for="day in timestampCalendarDays.filter(day => day !== null)"
                :key="day!.value"
                type="button"
                :data-date="day!.value"
                :aria-label="`Choose ${day!.label}`"
                :data-selected="day!.value === timestampNativeDateValue()"
                @click="selectTimestampCalendarDate(day!.value)"
              >
                {{ day!.day }}
              </button>
            </div>
          </div>
        </Teleport>
      </div>
      <label class="timestamp-hour-control">
        <span>{{ String(timestampHourValue()).padStart(2, '0') }}:00</span>
        <input
          :value="timestampHourValue()"
          type="range"
          min="0"
          max="23"
          step="1"
          aria-label="Timestamp hour"
          @input="updateTimestampHour(($event.target as HTMLInputElement).value)"
        >
      </label>
    </div>
    <input
      class="request-field-input timestamp-manual-input"
      :value="typeof value === 'string' ? value : ''"
      type="text"
      placeholder="2026-06-19T14:30:00Z"
      aria-label="Timestamp value"
      @input="$emit('update:value', ($event.target as HTMLInputElement).value || undefined)"
    >
  </div>

  <div v-else-if="isMessageField(field) && !wrapperScalarType(field)" class="message-field-editor">
    <div v-if="canUseStructuredMessage()" class="message-mode-control" aria-label="Message editor mode">
      <button type="button" :data-active="messageMode === 'form'" @click="setMessageMode('form')">
        <ListTree :size="13" aria-hidden="true" /> Form
      </button>
      <button type="button" :data-active="messageMode === 'json'" @click="setMessageMode('json')">
        <Braces :size="13" aria-hidden="true" /> JSON
      </button>
    </div>
    <div v-if="messageMode === 'form' && canUseStructuredMessage()" class="nested-field-list">
      <div v-for="nestedField in messageFields" :key="nestedField.name" class="nested-field-row">
        <span class="request-field-label">
          <strong>{{ nestedField.name }}</strong>
          <small>{{ nestedField.messageType || nestedField.type }}</small>
        </span>
        <RequestFieldEditor
          :field="nestedField"
          :value="isJsonObject(value) ? value[nestedField.jsonName || nestedField.name] : undefined"
          :message-types="messageTypes"
          :depth="depth + 1"
          :ancestor-types="nextAncestorTypes"
          @update:value="updateNestedField(nestedField, $event)"
        />
      </div>
    </div>
    <template v-else>
      <textarea
        class="request-field-input request-field-json"
        :value="jsonDraft"
        placeholder="{}"
        spellcheck="false"
        @input="updateJson(($event.target as HTMLTextAreaElement).value)"
      ></textarea>
      <span v-if="jsonError" class="field-validation-error">{{ jsonError }}</span>
    </template>
  </div>

  <select
    v-else-if="field.enumValues?.length"
    class="request-field-input"
    :value="typeof value === 'string' ? value : ''"
    @change="$emit('update:value', ($event.target as HTMLSelectElement).value || undefined)"
  >
    <option value="">Unset</option>
    <option v-for="enumValue in field.enumValues" :key="enumValue" :value="enumValue">{{ enumValue }}</option>
  </select>

  <input
    v-else-if="usesBooleanInput(field)"
    class="request-field-checkbox"
    :checked="Boolean(value)"
    type="checkbox"
    @change="$emit('update:value', ($event.target as HTMLInputElement).checked)"
  >

  <input
    v-else
    class="request-field-input"
    :value="value === undefined || value === null ? '' : String(value)"
    :type="usesNumberInput(field) ? 'number' : 'text'"
    @input="updateScalar(($event.target as HTMLInputElement).value)"
  >
</template>

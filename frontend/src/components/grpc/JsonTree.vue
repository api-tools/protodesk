<script setup lang="ts">
import {computed, ref} from 'vue'

const props = withDefaults(defineProps<{
  name?: string
  value: unknown
  query?: string
  root?: boolean
  last?: boolean
}>(), {
  name: '',
  query: '',
  root: false,
  last: true,
})

const open = ref(true)
const normalizedQuery = computed(() => props.query.trim().toLowerCase())
const isContainer = computed(() => isRecordLike(props.value))
const entries = computed(() => {
  if (!isRecordLike(props.value)) return []
  return Object.entries(props.value as Record<string, unknown>).filter(([key, value]) => {
    return matchesQuery(key, value, normalizedQuery.value)
  })
})
const openingToken = computed(() => Array.isArray(props.value) ? '[' : '{')
const closingToken = computed(() => Array.isArray(props.value) ? ']' : '}')

function isRecordLike(value: unknown): boolean {
  return Boolean(value) && typeof value === 'object'
}

function displayValue(value: unknown): string {
  if (typeof value === 'string') return JSON.stringify(value)
  return String(value)
}

function matchesQuery(key: string, value: unknown, query: string): boolean {
  if (!query) return true
  if (key.toLowerCase().includes(query)) return true
  if (!isRecordLike(value)) return displayValue(value).toLowerCase().includes(query)
  return Object.entries(value as Record<string, unknown>).some(([childKey, childValue]) => {
    return matchesQuery(childKey, childValue, query)
  })
}
</script>

<template>
  <div v-if="isContainer" class="json-node" :class="{ root }">
    <div class="json-line">
      <button class="json-toggle" type="button" @click="open = !open">
        {{ open ? '-' : '+' }}
      </button>
      <template v-if="!root">
        <span class="json-key">"{{ name }}"</span><span class="json-punctuation">:</span>
      </template>
      <span class="json-punctuation">{{ openingToken }}</span>
      <span v-if="!open" class="json-muted">...</span>
      <span v-if="!open" class="json-punctuation">{{ closingToken }}{{ last ? '' : ',' }}</span>
    </div>
    <div v-if="open" class="json-children">
      <JsonTree
        v-for="([key, childValue], index) in entries"
        :key="key"
        :name="key"
        :value="childValue"
        :query="query"
        :last="index === entries.length - 1"
      />
    </div>
    <div v-if="open" class="json-line json-closing">
      <span class="json-spacer"></span>
      <span class="json-punctuation">{{ closingToken }}{{ last ? '' : ',' }}</span>
    </div>
  </div>
  <div v-else class="json-line json-leaf">
    <span class="json-spacer"></span>
    <span class="json-key">"{{ name }}"</span><span class="json-punctuation">:</span>
    <code>{{ displayValue(value) }}{{ last ? '' : ',' }}</code>
  </div>
</template>

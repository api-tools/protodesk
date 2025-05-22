<script setup lang="ts">
import { defineProps, computed, ref, watch } from 'vue'

const props = defineProps<{
  responseData: any
  sendLoading: boolean
  sendError?: string
  selectedService?: string
  selectedMethod?: string
  responseTime?: number
  responseSize?: number
}>()

const searchQuery = ref('')
const currentMatchIndex = ref(-1)
const collapsedPaths = ref(new Set<string>())
const copySuccess = ref(false)

function findPathsWithMatch(value: any, query: string, currentPath: string = ''): string[] {
  const paths: string[] = []
  
  if (value === null || typeof value === 'boolean' || typeof value === 'number') {
    if (String(value).toLowerCase().includes(query.toLowerCase())) {
      paths.push(currentPath)
    }
  } else if (typeof value === 'string') {
    if (value.toLowerCase().includes(query.toLowerCase())) {
      paths.push(currentPath)
    }
  } else if (Array.isArray(value)) {
    value.forEach((item, index) => {
      const itemPaths = findPathsWithMatch(item, query, `${currentPath}[${index}]`)
      if (itemPaths.length > 0) {
        paths.push(currentPath, ...itemPaths)
      }
    })
  } else if (typeof value === 'object') {
    Object.entries(value).forEach(([key, val]) => {
      if (key.toLowerCase().includes(query.toLowerCase())) {
        paths.push(currentPath)
      }
      const valPaths = findPathsWithMatch(val, query, `${currentPath}.${key}`)
      if (valPaths.length > 0) {
        paths.push(currentPath, ...valPaths)
      }
    })
  }
  
  return paths
}

function expandPathsWithMatches() {
  if (!searchQuery.value || searchQuery.value.length < 2 || !props.responseData) return
  
  try {
    const json = JSON.parse(props.responseData)
    const paths = findPathsWithMatch(json, searchQuery.value)
    paths.forEach(path => collapsedPaths.value.delete(path))
  } catch (e) {
    console.error('Error expanding paths:', e)
  }
}

const searchResults = computed(() => {
  if (!searchQuery.value || searchQuery.value.length < 2 || !props.responseData) return { count: 0, matches: [] }
  
  const json = JSON.stringify(props.responseData, null, 2)
  const escapedQuery = searchQuery.value
    .replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    .replace(/"/g, '\\"')
  const regex = new RegExp(escapedQuery, 'gi')
  const matches = [...json.matchAll(regex)]
  
  return {
    count: matches.length,
    matches: matches.map(m => m.index)
  }
})

// Watch for changes in search query
watch(searchQuery, () => {
  // Reset the current match index when search query changes
  currentMatchIndex.value = -1
  
  if (searchQuery.value && searchQuery.value.length >= 2) {
    expandPathsWithMatches()
  }
})

function toggleCollapse(path: string) {
  if (collapsedPaths.value.has(path)) {
    collapsedPaths.value.delete(path)
  } else {
    collapsedPaths.value.add(path)
  }
}

function renderJsonValue(value: any, path: string = '', indent: number = 0): string {
  const indentStr = '  '.repeat(indent)
  
  if (value === null) {
    return '<span style="color: #f5faff; font-style: italic;">null</span>'
  }
  
  if (typeof value === 'boolean') {
    return `<span style="color: #f5faff;">${value}</span>`
  }
  
  if (typeof value === 'number') {
    return `<span style="color: #f5faff;">${value}</span>`
  }
  
  if (typeof value === 'string') {
    let content = value
    if (searchQuery.value && searchQuery.value.length >= 2) {
      const escapedQuery = searchQuery.value
        .replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
        .replace(/"/g, '\\"')
      const regex = new RegExp(escapedQuery, 'gi')
      content = value.replace(regex, match => `<span style="background-color: #42b983; color: #1b222c;">${match}</span>`)
    }
    return `<span style="color: #f5faff;">"${content}"</span>`
  }
  
  if (Array.isArray(value)) {
    if (value.length === 0) {
      return '[]'
    }
    const isCollapsed = collapsedPaths.value.has(path)
    const icon = isCollapsed ? '+' : '-'
    const style = `cursor: pointer; color: #42b983; margin-right: 4px; user-select: none; font-weight: bold;`
    const items = value.map((item, index) => renderJsonValue(item, `${path}[${index}]`, indent + 1)).join(',\n' + indentStr + '  ')
    return `<span class="collapsible" data-path="${path}" @click="toggleCollapse('${path}')" style="${style}">${icon}</span>[${isCollapsed ? '...' : `\n${indentStr}  ${items}\n${indentStr}`}]`
  }
  
  if (typeof value === 'object') {
    const entries = Object.entries(value)
    if (entries.length === 0) {
      return '{}'
    }
    const isCollapsed = collapsedPaths.value.has(path)
    const icon = isCollapsed ? '+' : '-'
    const style = `cursor: pointer; color: #42b983; margin-right: 4px; user-select: none; font-weight: bold;`
    const items = entries
      .map(([key, val]) => {
        let keyContent = key
        if (searchQuery.value && searchQuery.value.length >= 2) {
          const escapedQuery = searchQuery.value
            .replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
            .replace(/"/g, '\\"')
          const regex = new RegExp(escapedQuery, 'gi')
          keyContent = key.replace(regex, match => `<span style="background-color: #42b983; color: #1b222c;">${match}</span>`)
    }
        return `${indentStr}  <span style="color: #b0bec5;">"${keyContent}"</span>: ${renderJsonValue(val, `${path}.${key}`, indent + 1)}`
      })
      .join(',\n')
    return `<span class="collapsible" data-path="${path}" @click="toggleCollapse('${path}')" style="${style}">${icon}</span>{${isCollapsed ? '...' : `\n${items}\n${indentStr}`}}`
  }
  
  return ''
}

const formattedResponse = computed(() => {
  if (!props.responseData) return ''
  try {
    const json = JSON.parse(props.responseData)
    return renderJsonValue(json)
  } catch {
    return String(props.responseData)
  }
})

const formattedSize = computed(() => {
  if (!props.responseSize) return '0 KB'
  const kb = props.responseSize / 1024
  return `${kb.toFixed(2)} KB`
})

const disableNativeAutofill = () => {
  // Implementation of disableNativeAutofill function
}

function clearSearch() {
  searchQuery.value = ''
  currentMatchIndex.value = -1
  // Remove all selections
  const highlightedElements = document.querySelectorAll('span[style*="background-color"]')
  highlightedElements.forEach(el => {
    (el as HTMLElement).style.backgroundColor = ''
  })
}

function cycleNextMatch() {
  if (!searchResults.value.count) return
  currentMatchIndex.value = (currentMatchIndex.value + 1) % searchResults.value.count
  const matchIndex = searchResults.value.matches[currentMatchIndex.value]
  if (matchIndex !== undefined) {
    const element = document.querySelector('.response-content')
    if (element) {
      // Get all text nodes that contain our search query
      const walker = document.createTreeWalker(
        element,
        NodeFilter.SHOW_TEXT,
        null
      )
      
      let node: Text | null
      let currentIndex = 0
      let targetNode: Text | null = null
      
      while ((node = walker.nextNode() as Text)) {
        const text = node.textContent || ''
        const escapedQuery = searchQuery.value
          .replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
          .replace(/"/g, '\\"')
        const regex = new RegExp(escapedQuery, 'gi')
        const matches = [...text.matchAll(regex)]
        
        for (const match of matches) {
          if (currentIndex === currentMatchIndex.value) {
            targetNode = node
            break
          }
          currentIndex++
        }
        
        if (targetNode) break
      }
      
      if (targetNode) {
        const container = document.querySelector('.content-container')
        if (container) {
          // Remove previous selection
          const previousSelections = element.querySelectorAll('.current-match')
          previousSelections.forEach(el => {
            el.classList.remove('current-match')
          })
          
          // Create a span around the match
          const range = document.createRange()
          const startPos = targetNode.textContent?.toLowerCase().indexOf(searchQuery.value.toLowerCase()) || 0
          range.setStart(targetNode, startPos)
          range.setEnd(targetNode, startPos + searchQuery.value.length)
          
          const span = document.createElement('span')
          span.className = 'current-match'
          range.surroundContents(span)
          
          // Scroll to the match
          const containerRect = container.getBoundingClientRect()
          const targetRect = span.getBoundingClientRect()
          const scrollTop = targetRect.top - containerRect.top - (containerRect.height / 2) + container.scrollTop
          container.scrollTo({
            top: scrollTop,
            behavior: 'smooth'
          })
        }
      }
    }
  }
}

function handleKeyDown(event: KeyboardEvent) {
  if (event.key === 'Enter') {
    event.preventDefault()
    if (searchQuery.value && searchQuery.value.length >= 2) {
      if (currentMatchIndex.value === -1) {
        // First Enter press - start from the first match
        currentMatchIndex.value = 0
        // Find and highlight the first match without cycling
        const element = document.querySelector('.response-content')
        if (element) {
          const walker = document.createTreeWalker(
            element,
            NodeFilter.SHOW_TEXT,
            null
          )
          
          let node: Text | null
          let currentIndex = 0
          let targetNode: Text | null = null
          
          while ((node = walker.nextNode() as Text)) {
            const text = node.textContent || ''
            const escapedQuery = searchQuery.value
              .replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
              .replace(/"/g, '\\"')
            const regex = new RegExp(escapedQuery, 'gi')
            const matches = [...text.matchAll(regex)]
            
            if (matches.length > 0) {
              targetNode = node
              break
            }
          }
          
          if (targetNode) {
            const container = document.querySelector('.content-container')
            if (container) {
              // Remove previous selection
              const previousSelections = element.querySelectorAll('.current-match')
              previousSelections.forEach(el => {
                el.classList.remove('current-match')
              })
              
              // Create a span around the match
              const range = document.createRange()
              const startPos = targetNode.textContent?.toLowerCase().indexOf(searchQuery.value.toLowerCase()) || 0
              range.setStart(targetNode, startPos)
              range.setEnd(targetNode, startPos + searchQuery.value.length)
              
              const span = document.createElement('span')
              span.className = 'current-match'
              range.surroundContents(span)
              
              // Scroll to the match
              const containerRect = container.getBoundingClientRect()
              const targetRect = span.getBoundingClientRect()
              const scrollTop = targetRect.top - containerRect.top - (containerRect.height / 2) + container.scrollTop
              container.scrollTo({
                top: scrollTop,
                behavior: 'smooth'
              })
            }
          }
        }
      } else {
        cycleNextMatch()
      }
    }
  }
}

function handleCollapseClick(event: MouseEvent) {
  const target = event.target as HTMLElement
  if (target.classList.contains('collapsible')) {
    const path = target.getAttribute('data-path')
    if (path) {
      toggleCollapse(path)
    }
  }
}

async function copyToClipboard() {
  if (!props.responseData) return
  
  try {
    // If responseData is already an object, use it directly
    const json = typeof props.responseData === 'string' 
      ? JSON.parse(props.responseData) 
      : props.responseData
    await navigator.clipboard.writeText(JSON.stringify(json, null, 2))
    copySuccess.value = true
    setTimeout(() => {
      copySuccess.value = false
    }, 2000)
  } catch (err) {
    console.error('Failed to copy:', err)
  }
}
</script>
<template>
  <div style="width: 100%; height: 100%; display: flex; flex-direction: column; position: relative;">
    <!-- Fixed header -->
    <div style="height: 64px; min-height: 64px; max-height: 64px; background: #232b36; border-bottom: 1px solid #2c3e50; display: flex; align-items: center; justify-content: space-between; padding: 0 16px; flex-shrink: 0; position: absolute; top: 0; left: 0; right: 0; z-index: 1;">
      <div class="flex items-center h-full">
      <h2 class="font-bold text-white whitespace-nowrap">Response</h2>
    </div>
      <div class="flex items-center h-full gap-2">
        <div class="relative flex items-center">
          <div class="relative">
            <input
              v-model="searchQuery"
              type="text"
              placeholder="Search in response..."
              class="w-48 px-2 h-6 rounded bg-[#232b36] border border-[#2c3e50] text-white focus:outline-none text-[0.75rem] no-autofill"
              :style="{ width: searchQuery ? '200px' : '160px', paddingRight: searchQuery ? '24px' : '8px' }"
              autocomplete="off"
              autocorrect="off"
              autocapitalize="off"
              spellcheck="false"
              inputmode="none"
              @focus="disableNativeAutofill"
              @input="disableNativeAutofill"
              @keydown="handleKeyDown"
            />
            <button
              v-if="searchQuery"
              @click="clearSearch"
              class="absolute right-1 top-1/2 transform -translate-y-1/2 text-[#b0bec5] hover:text-white focus:outline-none text-[0.75rem]"
            >
              ×
            </button>
          </div>
          <div v-if="searchQuery && searchQuery.length >= 2 && searchResults.count > 0" class="text-[#42b983] text-[0.75rem] ml-2">
            {{ currentMatchIndex + 1 }}/{{ searchResults.count }} matches
          </div>
        </div>
        <div v-if="props.sendLoading" class="flex items-center gap-2 text-[#42b983]">
          <svg class="animate-spin h-4 w-4" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
            <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
          </svg>
          <span class="text-sm">Loading...</span>
        </div>
      </div>
    </div>

    <!-- Scrollable content -->
    <div class="content-container" style="flex: 1 1 0; min-height: 0; overflow: auto; padding: 16px; margin-top: 64px;">
    <div v-if="props.sendError" class="bg-red-900 text-red-200 rounded p-2 mb-2">{{ props.sendError }}</div>
      <div v-if="!props.sendLoading && !props.sendError && props.responseData" 
           class="bg-[#232b36] rounded p-2 font-mono text-xs whitespace-pre-wrap response-content" 
           style="min-height: 120px; color: #b0bec5;" 
           v-html="formattedResponse" 
           @click="handleCollapseClick">
    </div>
    <div v-else-if="!props.sendLoading && !props.sendError && !props.responseData" class="text-[#b0bec5] mt-2">
      No response yet. Click <span class="font-bold">Send</span> to make a request.
      </div>
    </div>

    <!-- Status bar -->
    <div style="height: 28px; min-height: 28px; max-height: 28px; background: #1b222c; border-top: 1px solid #2c3e50; display: flex; align-items: center; justify-content: space-between; padding-left: 16px; padding-right: 8px; font-size: 0.75rem; flex-shrink: 0; color: #fff; margin: 0; gap: 8px;">
      <div class="flex items-center gap-2">
        <template v-if="!props.sendLoading && !props.sendError && props.responseData">
          <span class="text-[#b0bec5]">Response time: <span class="text-[#42b983]">{{ props.responseTime }}ms</span></span>
          <span class="text-[#b0bec5]">Size: <span class="text-[#42b983]">{{ formattedSize }}</span></span>
        </template>
      </div>
      <div class="flex items-center">
        <button 
          v-if="!props.sendLoading && !props.sendError && props.responseData"
          @click="copyToClipboard"
          class="text-[#42b983] hover:text-[#42b983] hover:opacity-80 transition-colors duration-200 p-1"
          title="Copy response to clipboard"
        >
          <svg v-if="!copySuccess" xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>
            <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>
          </svg>
          <svg v-else xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <polyline points="20 6 9 17 4 12"></polyline>
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

.collapsible {
  display: inline-block;
  transition: transform 0.2s;
}

.collapsible:hover {
  opacity: 0.8;
}

.current-match {
  outline: 2px solid #42b983 !important;
  outline-offset: 2px !important;
  background-color: #42b983 !important;
  color: #1b222c !important;
}
</style> 
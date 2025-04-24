import { defineStore } from 'pinia'
import { ref } from 'vue'

export interface ProtoFile {
  id: string
  name: string
  content: string
  path?: string
  imports: string[]
  services: ProtoService[]
  createdAt: Date
  updatedAt: Date
}

export interface ProtoService {
  name: string
  methods: ProtoMethod[]
}

export interface ProtoMethod {
  name: string
  inputType: string
  outputType: string
  isClientStreaming: boolean
  isServerStreaming: boolean
}

export const useProtoFileStore = defineStore('protoFile', () => {
  const files = ref<ProtoFile[]>([])
  const activeFile = ref<ProtoFile | null>(null)

  function addFile(file: ProtoFile) {
    files.value.push(file)
  }

  function updateFile(id: string, updates: Partial<ProtoFile>) {
    const index = files.value.findIndex(f => f.id === id)
    if (index !== -1) {
      files.value[index] = { ...files.value[index], ...updates }
    }
  }

  function removeFile(id: string) {
    files.value = files.value.filter(f => f.id !== id)
    if (activeFile.value?.id === id) {
      activeFile.value = null
    }
  }

  function setActiveFile(id: string | null) {
    activeFile.value = id ? files.value.find(f => f.id === id) || null : null
  }

  return {
    files,
    activeFile,
    addFile,
    updateFile,
    removeFile,
    setActiveFile
  }
})

import { defineStore } from 'pinia'
import { ref } from 'vue'

export interface ServerProfile {
  id: string
  name: string
  host: string
  port: number
  tlsEnabled: boolean
  certificatePath?: string
  createdAt: Date
  updatedAt: Date
}

export const useServerProfileStore = defineStore('serverProfile', () => {
  const profiles = ref<ServerProfile[]>([])
  const activeProfile = ref<ServerProfile | null>(null)

  function addProfile(profile: ServerProfile) {
    profiles.value.push(profile)
  }

  function updateProfile(id: string, updates: Partial<ServerProfile>) {
    const index = profiles.value.findIndex(p => p.id === id)
    if (index !== -1) {
      profiles.value[index] = { ...profiles.value[index], ...updates }
    }
  }

  function removeProfile(id: string) {
    profiles.value = profiles.value.filter(p => p.id !== id)
    if (activeProfile.value?.id === id) {
      activeProfile.value = null
    }
  }

  function setActiveProfile(id: string | null) {
    activeProfile.value = id ? profiles.value.find(p => p.id === id) || null : null
  }

  return {
    profiles,
    activeProfile,
    addProfile,
    updateProfile,
    removeProfile,
    setActiveProfile
  }
})

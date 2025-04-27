import { defineStore } from 'pinia'
import { ref } from 'vue'
import * as AppAPI from '../../wailsjs/go/app/App'
import { models } from '../../wailsjs/go/models'

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

function toFrontendProfile(profile: any): ServerProfile {
  return {
    ...profile,
    createdAt: new Date(profile.createdAt),
    updatedAt: new Date(profile.updatedAt)
  }
}

export const useServerProfileStore = defineStore('serverProfile', () => {
  const profiles = ref<ServerProfile[]>([])
  const activeProfile = ref<ServerProfile | null>(null)

  async function loadProfiles() {
    const backendProfiles = await AppAPI.ListServerProfiles()
    profiles.value = backendProfiles.map(toFrontendProfile)
  }

  async function addProfile(profile: ServerProfile) {
    const created = await AppAPI.CreateServerProfile(
      profile.name,
      profile.host,
      profile.port,
      profile.tlsEnabled,
      profile.certificatePath || null
    )
    profiles.value.push(toFrontendProfile(created))
  }

  async function updateProfile(id: string, updates: Partial<ServerProfile>) {
    const index = profiles.value.findIndex(p => p.id === id)
    if (index !== -1) {
      const updatedProfile = { ...profiles.value[index], ...updates }
      const backendProfile = new models.ServerProfile({
        ...updatedProfile,
        createdAt: updatedProfile.createdAt.toISOString(),
        updatedAt: new Date().toISOString()
      })
      await AppAPI.UpdateServerProfile(backendProfile)
      profiles.value[index] = { ...updatedProfile, updatedAt: new Date() }
    }
  }

  async function removeProfile(id: string) {
    await AppAPI.DeleteServerProfile(id)
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
    loadProfiles,
    addProfile,
    updateProfile,
    removeProfile,
    setActiveProfile
  }
})

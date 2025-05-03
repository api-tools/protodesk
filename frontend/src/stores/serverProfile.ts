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
  protoFolders?: string[]
  useReflection?: boolean
  headers?: { key: string, value: string }[]
}

function toFrontendProfile(profile: any): ServerProfile {
  return {
    ...profile,
    createdAt: new Date(profile.createdAt),
    updatedAt: new Date(profile.updatedAt),
    protoFolders: Array.isArray(profile.protoFolders) ? profile.protoFolders : [],
    useReflection: profile.useReflection ?? false,
    headers: Array.isArray(profile.headers) ? profile.headers : []
  }
}

export const useServerProfileStore = defineStore('serverProfile', () => {
  const profiles = ref<ServerProfile[]>([])
  const activeProfile = ref<ServerProfile | null>(null)

  async function loadProfiles() {
    const backendProfiles = await AppAPI.ListServerProfiles()
    profiles.value = (backendProfiles ?? []).map(toFrontendProfile)
    console.log('[DEBUG] Pinia store profiles after load:', profiles.value)
  }

  async function addProfile(profile: ServerProfile) {
    const created = await AppAPI.CreateServerProfile(
      profile.name,
      profile.host,
      profile.port,
      profile.tlsEnabled,
      profile.certificatePath || null,
      profile.useReflection ?? false,
      profile.headers ?? []
    )
    // Add proto paths and scan/parse proto files for each protoFolder
    if (profile.protoFolders && profile.protoFolders.length > 0) {
      await Promise.all(profile.protoFolders.map(async (folder) => {
        // Generate a random ID for the proto path
        const protoPathId = Math.random().toString(36).substring(2, 12);
        await AppAPI.ScanAndParseProtoPath(created.id, protoPathId, folder);
      }))
    }
    profiles.value.push(toFrontendProfile(created))
    return toFrontendProfile(created)
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
    await loadProfiles()
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

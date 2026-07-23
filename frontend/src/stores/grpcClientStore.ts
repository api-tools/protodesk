import {defineStore} from 'pinia'
import {
  ClearHistory,
  Connect,
  CreateCollection,
  CreateCollectionRequest,
  CreateHistoryItem,
  CreateServerProfile,
  DeleteCollection,
  DeleteCollectionRequest,
  DeleteHistoryItem,
  DeleteServerProfile,
  Disconnect,
  ExportWorkspace,
  ImportWorkspace,
  Invoke,
  ListCollections,
  ListHistoryItems,
  ListServerProfiles,
  UpdateCollection,
  UpdateCollectionRequest,
  UpdateServerProfile,
} from '../../wailsjs/go/main/App'
import type {
  CallOptions,
  Collection,
  CollectionRequest,
  ConnectionStateData,
  GrpcMethod,
  GrpcRequestDraft,
  GrpcResponse,
  GrpcService,
  HistoryItem,
  MetadataEntry,
  ServerProfile,
  StatusMessage,
  WorkspaceTransferResult,
} from '../types/grpc'
import {formatJson, validateJson} from '../utils/json'

const defaultOptions: CallOptions = {
  timeoutMs: 5000,
  authority: '',
}

const localWorkspaceId = 'local'

const defaultServerProfile: ServerProfile = {
  workspaceId: localWorkspaceId,
  id: 'local-default',
  name: 'Local gRPC',
  address: 'localhost:50051',
  tlsEnabled: false,
  reflectionEnabled: true,
  protoFiles: [],
  protoFolders: [],
  metadataJson: '{}',
}

export const useGrpcClientStore = defineStore('grpcClient', {
  state: () => ({
    connection: {
      state: 'disconnected',
      serverAddress: 'localhost:50051',
      tlsEnabled: false,
      reflectionEnabled: true,
      error: '',
      reflectionUnavailable: false,
      descriptorSource: 'none',
      protoSourceError: '',
    } as ConnectionStateData,
    services: [] as GrpcService[],
    serverProfiles: [{...defaultServerProfile}] as ServerProfile[],
    selectedServerId: 'local-default',
    profilesLoaded: false,
    profilesLoading: false,
    selectedMethod: null as GrpcMethod | null,
    request: {
      bodyJson: '{}',
      metadata: [] as MetadataEntry[],
      options: {...defaultOptions},
      validationError: '',
    } as GrpcRequestDraft,
    response: null as GrpcResponse | null,
    isInvoking: false,
    historyItems: [] as HistoryItem[],
    historyLoading: false,
    historyModalOpen: false,
    selectedHistoryItemId: '',
    collections: [] as Collection[],
    collectionsLoading: false,
    collectionsModalOpen: false,
    selectedCollectionId: '',
    selectedCollectionRequestId: '',
    workspaceModalOpen: false,
    workspaceTransferLoading: false,
    workspaceTransferResult: null as WorkspaceTransferResult | null,
    status: {
      level: 'idle',
      message: 'Disconnected',
    } as StatusMessage,
  }),

  getters: {
    canInvoke(state): boolean {
      return state.connection.state === 'connected'
        && Boolean(state.selectedMethod)
        && !state.isInvoking
        && validateJson(state.request.bodyJson).valid
    },
    enabledMetadata(state): Record<string, string> {
      return state.request.metadata.reduce<Record<string, string>>((headers, entry) => {
        const key = entry.key.trim()
        if (entry.enabled && key && entry.value.trim()) {
          headers[key] = entry.value
        }
        return headers
      }, {})
    },
    selectedServer(state): ServerProfile | null {
      return state.serverProfiles.find((server) => server.id === state.selectedServerId) ?? null
    },
    selectedHistoryItem(state): HistoryItem | null {
      return state.historyItems.find((item) => item.id === state.selectedHistoryItemId) ?? state.historyItems[0] ?? null
    },
    selectedCollection(state): Collection | null {
      return state.collections.find((collection) => collection.id === state.selectedCollectionId) ?? state.collections[0] ?? null
    },
    selectedCollectionRequest(state): CollectionRequest | null {
      const requests = state.collections.flatMap((collection) => collection.requests)
      return requests.find((request) => request.id === state.selectedCollectionRequestId)
        ?? (state.collections.find((collection) => collection.id === state.selectedCollectionId)?.requests[0] ?? requests[0] ?? null)
    },
  },

  actions: {
    async loadServerProfiles() {
      if (this.profilesLoading || this.profilesLoaded) return

      this.profilesLoading = true
      try {
        const profiles = normalizeServerProfiles(await ListServerProfiles())
        this.serverProfiles = profiles.length > 0 ? profiles : [{...defaultServerProfile}]
        const selected = this.serverProfiles.find((server) => server.id === this.selectedServerId) ?? this.serverProfiles[0]
        if (selected) {
          this.applyServerProfile(selected)
        }
        this.profilesLoaded = true
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        this.status = {level: 'error', message: `Could not load server profiles: ${message}`}
      } finally {
        this.profilesLoading = false
      }
    },

    openWorkspaceModal() {
      this.workspaceModalOpen = true
    },

    closeWorkspaceModal() {
      this.workspaceModalOpen = false
    },

    async exportWorkspace() {
      this.workspaceTransferLoading = true
      try {
        const result = await ExportWorkspace()
        this.workspaceTransferResult = result
        this.status = result.skipped
          ? {level: 'idle', message: 'Workspace export cancelled'}
          : {level: 'success', message: `Exported workspace · ${result.serverCount} servers · ${result.savedRequestCount} requests`}
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        this.status = {level: 'error', message: `Could not export workspace: ${message}`}
      } finally {
        this.workspaceTransferLoading = false
      }
    },

    async importWorkspace() {
      this.workspaceTransferLoading = true
      try {
        const result = await ImportWorkspace()
        this.workspaceTransferResult = result
        if (!result.skipped) {
          this.profilesLoaded = false
          await this.loadServerProfiles()
          await this.loadCollections()
        }
        this.status = result.skipped
          ? {level: 'idle', message: 'Workspace import cancelled'}
          : {level: 'success', message: `Imported workspace · ${result.serverCount} servers · ${result.savedRequestCount} requests`}
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        this.status = {level: 'error', message: `Could not import workspace: ${message}`}
      } finally {
        this.workspaceTransferLoading = false
      }
    },

    applyServerProfile(profile: ServerProfile) {
      this.selectedServerId = profile.id
      this.connection.serverAddress = profile.address
      this.connection.tlsEnabled = profile.tlsEnabled
      this.connection.reflectionEnabled = profile.reflectionEnabled
      this.connection.error = ''
    },

    selectServerProfile(id: string) {
      const profile = this.serverProfiles.find((server) => server.id === id)
      if (profile) {
        this.applyServerProfile(profile)
      }
    },

    async createServerProfile(profile: Omit<ServerProfile, 'id' | 'workspaceId'>) {
      try {
        const server = normalizeServerProfile(await CreateServerProfile(profile))
        this.serverProfiles = [...this.serverProfiles.filter((item) => item.id !== defaultServerProfile.id), server]
        this.applyServerProfile(server)
        this.status = {level: 'success', message: `Saved server ${server.name}`}
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        this.status = {level: 'error', message: `Could not save server profile: ${message}`}
      }
    },

    async updateServerProfile(id: string, patch: Partial<Omit<ServerProfile, 'id' | 'workspaceId'>>) {
      const index = this.serverProfiles.findIndex((server) => server.id === id)
      if (index < 0) return
      const updated = {...this.serverProfiles[index], ...patch}
      try {
        const saved = normalizeServerProfile(await UpdateServerProfile(id, serverProfileRequest(updated)))
        this.serverProfiles[index] = saved
        if (this.selectedServerId === id) {
          this.applyServerProfile(saved)
        }
        this.status = {level: 'success', message: `Saved server ${saved.name}`}
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        this.status = {level: 'error', message: `Could not save server profile: ${message}`}
      }
    },

    async deleteServerProfile(id: string) {
      const index = this.serverProfiles.findIndex((server) => server.id === id)
      if (index < 0) return
      try {
        await DeleteServerProfile(id)
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        this.status = {level: 'error', message: `Could not delete server profile: ${message}`}
        return
      }
      this.serverProfiles.splice(index, 1)
      if (this.selectedServerId === id) {
        const next = this.serverProfiles[0] ?? null
        if (next) {
          this.applyServerProfile(next)
        } else {
          this.selectedServerId = ''
          this.connection.serverAddress = ''
          this.connection.tlsEnabled = false
          this.connection.reflectionEnabled = true
        }
      }
      this.status = {level: 'success', message: 'Server profile deleted'}
    },

    async openHistoryModal() {
      this.historyModalOpen = true
      await this.loadHistoryItems()
    },

    closeHistoryModal() {
      this.historyModalOpen = false
    },

    async loadHistoryItems(limit = 100) {
      this.historyLoading = true
      try {
        this.historyItems = normalizeHistoryItems(await ListHistoryItems(limit))
        if (!this.selectedHistoryItemId || !this.historyItems.some((item) => item.id === this.selectedHistoryItemId)) {
          this.selectedHistoryItemId = this.historyItems[0]?.id ?? ''
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        this.status = {level: 'error', message: `Could not load history: ${message}`}
      } finally {
        this.historyLoading = false
      }
    },

    selectHistoryItem(id: string) {
      this.selectedHistoryItemId = id
    },

    async deleteHistoryItem(id: string) {
      try {
        await DeleteHistoryItem(id)
        this.historyItems = this.historyItems.filter((item) => item.id !== id)
        if (this.selectedHistoryItemId === id) {
          this.selectedHistoryItemId = this.historyItems[0]?.id ?? ''
        }
        this.status = {level: 'success', message: 'History item deleted'}
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        this.status = {level: 'error', message: `Could not delete history item: ${message}`}
      }
    },

    async clearHistory() {
      try {
        await ClearHistory()
        this.historyItems = []
        this.selectedHistoryItemId = ''
        this.status = {level: 'success', message: 'History cleared'}
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        this.status = {level: 'error', message: `Could not clear history: ${message}`}
      }
    },

    loadHistoryRequest(item: HistoryItem) {
      const method = findMethodByFullName(this.services, item.fullMethod)
      if (method) {
        this.selectedMethod = method
      }
      this.request.bodyJson = item.requestJson || '{}'
      this.request.validationError = ''
      this.request.metadata = metadataRowsFromJson(item.requestMetadataJson)
      this.response = itemToResponse(item)
      this.closeHistoryModal()
      this.status = method
        ? {level: 'info', message: `Loaded ${item.serviceName}/${item.methodName} from history`}
        : {level: 'warning', message: `Loaded request body from history · method not available`}
    },

    async openCollectionsModal() {
      this.collectionsModalOpen = true
      await this.loadCollections()
    },

    closeCollectionsModal() {
      this.collectionsModalOpen = false
    },

    async loadCollections() {
      this.collectionsLoading = true
      try {
        this.collections = normalizeCollections(await ListCollections())
        if (!this.selectedCollectionId || !this.collections.some((collection) => collection.id === this.selectedCollectionId)) {
          this.selectedCollectionId = this.collections[0]?.id ?? ''
        }
        if (!this.selectedCollectionRequestId || !this.collections.some((collection) => collection.requests.some((request) => request.id === this.selectedCollectionRequestId))) {
          this.selectedCollectionRequestId = this.selectedCollection?.requests[0]?.id ?? ''
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        this.status = {level: 'error', message: `Could not load collections: ${message}`}
      } finally {
        this.collectionsLoading = false
      }
    },

    selectCollection(id: string) {
      this.selectedCollectionId = id
      this.selectedCollectionRequestId = this.selectedCollection?.requests[0]?.id ?? ''
    },

    selectCollectionRequest(id: string) {
      this.selectedCollectionRequestId = id
    },

    async createCollection(name = 'Personal', description = ''): Promise<Collection | null> {
      try {
        const collection = normalizeCollection(await CreateCollection({name, description}))
        this.collections = [collection, ...this.collections]
        this.selectedCollectionId = collection.id
        this.status = {level: 'success', message: `Created collection ${collection.name}`}
        return collection
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        this.status = {level: 'error', message: `Could not create collection: ${message}`}
        return null
      }
    },

    async updateCollection(id: string, patch: Pick<Collection, 'name' | 'description'>) {
      try {
        const updated = normalizeCollection(await UpdateCollection(id, patch))
        const index = this.collections.findIndex((collection) => collection.id === id)
        if (index >= 0) {
          this.collections[index] = {...updated, requests: this.collections[index].requests}
        }
        this.status = {level: 'success', message: `Saved collection ${updated.name}`}
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        this.status = {level: 'error', message: `Could not save collection: ${message}`}
      }
    },

    async deleteCollection(id: string) {
      try {
        await DeleteCollection(id)
        this.collections = this.collections.filter((collection) => collection.id !== id)
        if (this.selectedCollectionId === id) {
          this.selectedCollectionId = this.collections[0]?.id ?? ''
          this.selectedCollectionRequestId = this.selectedCollection?.requests[0]?.id ?? ''
        }
        this.status = {level: 'success', message: 'Collection deleted'}
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        this.status = {level: 'error', message: `Could not delete collection: ${message}`}
      }
    },

    async saveCurrentRequestToCollection(collectionId: string, name: string) {
      if (!this.selectedMethod) {
        this.status = {level: 'error', message: 'Select a method before saving a request'}
        return
      }
      const collection = await this.ensureCollection(collectionId)
      if (!collection) return
      const server = this.selectedServer
      await this.createCollectionRequest({
        collectionId: collection.id,
        name: name.trim() || this.selectedMethod.methodName,
        serverId: server?.id ?? '',
        serverName: server?.name ?? this.connection.serverAddress,
        serverAddress: this.connection.serverAddress,
        serviceName: this.selectedMethod.serviceName,
        methodName: this.selectedMethod.methodName,
        fullMethod: this.selectedMethod.fullName,
        requestJson: this.request.bodyJson,
        requestMetadataJson: JSON.stringify(this.enabledMetadata, null, 2),
      })
    },

    async saveHistoryItemToCollection(item: HistoryItem, collectionId: string, name: string) {
      const collection = await this.ensureCollection(collectionId)
      if (!collection) return
      await this.createCollectionRequest({
        collectionId: collection.id,
        name: name.trim() || item.methodName,
        serverId: item.serverId,
        serverName: item.serverName,
        serverAddress: item.serverAddress,
        serviceName: item.serviceName,
        methodName: item.methodName,
        fullMethod: item.fullMethod,
        requestJson: item.requestJson,
        requestMetadataJson: item.requestMetadataJson,
      })
    },

    async createCollectionRequest(request: Omit<CollectionRequest, 'workspaceId' | 'id' | 'createdAt' | 'updatedAt'>) {
      try {
        const saved = normalizeCollectionRequest(await CreateCollectionRequest(request))
        this.upsertCollectionRequest(saved)
        this.selectedCollectionId = saved.collectionId
        this.selectedCollectionRequestId = saved.id
        this.status = {level: 'success', message: `Saved request ${saved.name}`}
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        this.status = {level: 'error', message: `Could not save request: ${message}`}
      }
    },

    async updateCollectionRequest(id: string, request: Omit<CollectionRequest, 'workspaceId' | 'id' | 'createdAt' | 'updatedAt'>) {
      try {
        const saved = normalizeCollectionRequest(await UpdateCollectionRequest(id, request))
        this.upsertCollectionRequest(saved)
        this.status = {level: 'success', message: `Saved request ${saved.name}`}
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        this.status = {level: 'error', message: `Could not save request: ${message}`}
      }
    },

    async deleteCollectionRequest(id: string) {
      try {
        await DeleteCollectionRequest(id)
        this.collections = this.collections.map((collection) => ({
          ...collection,
          requests: collection.requests.filter((request) => request.id !== id),
        }))
        if (this.selectedCollectionRequestId === id) {
          this.selectedCollectionRequestId = this.selectedCollection?.requests[0]?.id ?? ''
        }
        this.status = {level: 'success', message: 'Saved request deleted'}
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        this.status = {level: 'error', message: `Could not delete saved request: ${message}`}
      }
    },

    loadCollectionRequest(item: CollectionRequest) {
      const method = findMethodByFullName(this.services, item.fullMethod)
      if (method) {
        this.selectedMethod = method
      }
      this.request.bodyJson = item.requestJson || '{}'
      this.request.validationError = ''
      this.request.metadata = metadataRowsFromJson(item.requestMetadataJson)
      this.response = null
      this.closeCollectionsModal()
      this.status = method
        ? {level: 'info', message: `Loaded ${item.serviceName}/${item.methodName} from collections`}
        : {level: 'warning', message: `Loaded saved request · method not available`}
    },

    async ensureCollection(collectionId: string): Promise<Collection | null> {
      const existing = this.collections.find((collection) => collection.id === collectionId)
      if (existing) return existing
      return this.createCollection('Personal', '')
    },

    upsertCollectionRequest(request: CollectionRequest) {
      const collectionIndex = this.collections.findIndex((collection) => collection.id === request.collectionId)
      if (collectionIndex < 0) return
      this.collections = this.collections.map((collection, index) => {
        if (index !== collectionIndex) {
          return {...collection, requests: collection.requests.filter((item) => item.id !== request.id)}
        }
        const requests = [request, ...collection.requests.filter((item) => item.id !== request.id)]
        return {...collection, requests}
      })
    },

    setServerAddress(serverAddress: string) {
      this.connection.serverAddress = serverAddress
      this.selectedServerId = ''
    },

    setTlsEnabled(enabled: boolean) {
      this.connection.tlsEnabled = enabled
    },

    setReflectionEnabled(enabled: boolean) {
      this.connection.reflectionEnabled = enabled
    },

    async connect() {
      const address = this.connection.serverAddress.trim()
      const addressError = validateServerAddress(address)
      if (addressError) {
        this.connection.error = addressError
        this.connection.state = 'failed'
        this.status = {level: 'error', message: `Error: ${addressError}`}
        return
      }

      try {
        const selectedServer = this.selectedServer
        const serverMetadata = parseMetadataJson(selectedServer?.metadataJson ?? '{}')
        this.connection.state = 'connecting'
        this.connection.error = ''
        this.connection.reflectionUnavailable = false
        this.connection.descriptorSource = 'none'
        this.connection.protoSourceError = ''
        this.status = {level: 'info', message: `Connecting to ${address}...`}
        const result = await Connect({
          serverAddress: address,
          tlsEnabled: this.connection.tlsEnabled,
          reflectionEnabled: this.connection.reflectionEnabled,
          protoFiles: selectedServer?.protoFiles ?? [],
          protoFolders: selectedServer?.protoFolders ?? [],
          metadata: serverMetadata,
        })
        this.connection.state = 'connected'
        this.services = result.services ?? []
        this.connection.error = result.error ?? ''
        this.connection.reflectionUnavailable = Boolean(result.reflectionUnavailable)
        const descriptorSource = result.descriptorSource === 'reflection' || result.descriptorSource === 'proto'
          ? result.descriptorSource
          : 'none'
        this.connection.descriptorSource = descriptorSource
        this.connection.protoSourceError = result.protoSourceError ?? ''
        if (result.protoSourceError) {
          this.status = {level: 'warning', message: `Connected to ${address} · proto sources unavailable`}
        } else if (descriptorSource === 'proto' && result.reflectionUnavailable) {
          this.status = {level: 'warning', message: `Connected to ${address} · using proto files · reflection unavailable`}
        } else if (descriptorSource === 'proto') {
          this.status = {level: 'success', message: `Connected to ${address} · using proto files`}
        } else if (result.reflectionUnavailable) {
          this.status = {level: 'warning', message: `Connected to ${address} · reflection unavailable`}
        } else {
          this.status = {level: 'success', message: `Connected to ${address}`}
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        this.connection.state = 'failed'
        this.connection.error = message
        this.services = []
        this.selectedMethod = null
        this.status = {level: 'error', message: `Error: ${message}`}
      }
    },

    async disconnect() {
      await Disconnect()
      this.connection.state = 'disconnected'
      this.connection.error = ''
      this.connection.reflectionUnavailable = false
      this.connection.descriptorSource = 'none'
      this.connection.protoSourceError = ''
      this.services = []
      this.selectedMethod = null
      this.response = null
      this.status = {level: 'idle', message: 'Disconnected'}
    },

    selectMethod(method: GrpcMethod) {
      this.selectedMethod = method
      this.request.bodyJson = defaultRequestBody(method)
      this.request.validationError = ''
      this.response = null
      this.status = {
        level: 'info',
        message: `${method.serviceName}/${method.methodName} selected`,
      }
    },

    setRequestBody(bodyJson: string) {
      this.request.bodyJson = bodyJson
      const validation = validateJson(bodyJson)
      this.request.validationError = validation.valid ? '' : `Invalid JSON request body: ${validation.error}`
    },

    addMetadataRow() {
      this.request.metadata.push({key: '', value: '', enabled: true})
    },

    updateMetadataEntry(index: number, patch: Partial<MetadataEntry>) {
      const entry = this.request.metadata[index]
      if (!entry) return
      this.request.metadata[index] = {...entry, ...patch}
    },

    removeMetadataEntry(index: number) {
      this.request.metadata.splice(index, 1)
    },

    updateCallOptions(patch: Partial<CallOptions>) {
      this.request.options = {...this.request.options, ...patch}
    },

    async invoke() {
      if (!this.selectedMethod) {
        this.status = {level: 'error', message: 'Error: select a method before invoking'}
        return
      }
      if (this.connection.state !== 'connected') {
        this.status = {level: 'error', message: 'Error: no server connected'}
        return
      }

      const validation = validateJson(this.request.bodyJson)
      if (!validation.valid) {
        this.request.validationError = `Invalid JSON request body: ${validation.error}`
        this.status = {level: 'error', message: 'Invalid JSON request body'}
        return
      }

      this.isInvoking = true
      this.response = null
      this.request.validationError = ''
      this.status = {level: 'info', message: `Invoking ${this.selectedMethod.serviceName}/${this.selectedMethod.methodName}...`}

      try {
        const selectedServer = this.selectedServer
        const serverMetadata = parseMetadataJson(selectedServer?.metadataJson ?? '{}')
        const requestMetadata = {...serverMetadata, ...this.enabledMetadata}
        const result = await Invoke({
          serverAddress: this.connection.serverAddress,
          fullMethod: this.selectedMethod.fullName,
          bodyJson: this.request.bodyJson,
          metadata: requestMetadata,
          timeoutMs: Number(this.request.options.timeoutMs) || 5000,
          authority: this.request.options.authority || '',
        })
        this.response = normalizeResponse(result)
        const historySaved = await this.recordHistoryItem(selectedServer, this.selectedMethod, requestMetadata, this.response)
        if (historySaved) {
          this.status = this.response.ok
            ? {level: 'success', message: `${this.selectedMethod.serviceName}/${this.selectedMethod.methodName} · ${this.response.statusCode} · ${this.response.durationMs} ms`}
            : {level: 'error', message: `Invoke failed · ${this.response.statusCode} · ${this.response.durationMs} ms`}
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        this.response = {
          ok: false,
          statusCode: 'INTERNAL',
          statusMessage: message,
          durationMs: 0,
          error: message,
        }
        this.status = {level: 'error', message: `Invoke failed · ${message}`}
      } finally {
        this.isInvoking = false
      }
    },

    async recordHistoryItem(
      server: ServerProfile | null,
      method: GrpcMethod,
      requestMetadata: Record<string, string>,
      response: GrpcResponse,
    ): Promise<boolean> {
      try {
        const item = normalizeHistoryItem(await CreateHistoryItem({
          serverId: server?.id ?? '',
          serverName: server?.name ?? this.connection.serverAddress,
          serverAddress: this.connection.serverAddress,
          serviceName: method.serviceName,
          methodName: method.methodName,
          fullMethod: method.fullName,
          requestJson: this.request.bodyJson,
          requestMetadataJson: JSON.stringify(requestMetadata, null, 2),
          responseJson: response.bodyJson || '{}',
          statusCode: response.statusCode,
          statusMessage: response.statusMessage || '',
          durationMs: response.durationMs,
          error: response.error || '',
        }))
        this.historyItems = [item, ...this.historyItems.filter((historyItem) => historyItem.id !== item.id)].slice(0, 100)
        this.selectedHistoryItemId = item.id
        return true
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        this.status = {level: 'warning', message: `Invoke completed but history was not saved: ${message}`}
        return false
      }
    },
  },
})

function defaultRequestBody(method: GrpcMethod): string {
  const requestType = method.requestType.toLowerCase()
  if (requestType.endsWith('.empty') || requestType === 'empty') {
    return '{}'
  }
  return formatJson({})
}

function normalizeResponse(response: GrpcResponse): GrpcResponse {
  return {
    ...response,
    bodyJson: response.bodyJson ? response.bodyJson : '{}',
  }
}

function validateServerAddress(address: string): string {
  if (!address) {
    return 'server address is required'
  }
  if (address.includes('://')) {
    return 'server address must not include a protocol prefix'
  }
  const parts = address.split(':')
  if (parts.length !== 2 || !parts[0].trim() || !parts[1].trim()) {
    return 'server address must be in host:port format'
  }
  const port = Number(parts[1])
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    return 'server port must be between 1 and 65535'
  }
  return ''
}

function parseMetadataJson(metadataJson: string): Record<string, string> {
  const trimmed = metadataJson.trim()
  if (!trimmed) return {}

  const parsed = JSON.parse(trimmed)
  if (!parsed || Array.isArray(parsed) || typeof parsed !== 'object') {
    throw new Error('server metadata must be a JSON object')
  }

  return Object.entries(parsed).reduce<Record<string, string>>((headers, [key, value]) => {
    if (typeof value !== 'string') {
      throw new Error(`server metadata value for "${key}" must be a string`)
    }
    if (key.trim() && value.trim()) {
      headers[key] = value
    }
    return headers
  }, {})
}

function normalizeServerProfiles(profiles: ServerProfile[] | null | undefined): ServerProfile[] {
  return (profiles ?? []).map(normalizeServerProfile)
}

function normalizeServerProfile(profile: ServerProfile): ServerProfile {
  return {
    workspaceId: profile.workspaceId || localWorkspaceId,
    id: profile.id,
    name: profile.name,
    address: profile.address,
    tlsEnabled: Boolean(profile.tlsEnabled),
    reflectionEnabled: Boolean(profile.reflectionEnabled),
    protoFiles: profile.protoFiles ?? [],
    protoFolders: profile.protoFolders ?? [],
    metadataJson: profile.metadataJson?.trim() || '{}',
  }
}

function serverProfileRequest(profile: ServerProfile): Omit<ServerProfile, 'id' | 'workspaceId'> {
  return {
    name: profile.name,
    address: profile.address,
    tlsEnabled: profile.tlsEnabled,
    reflectionEnabled: profile.reflectionEnabled,
    protoFiles: profile.protoFiles,
    protoFolders: profile.protoFolders,
    metadataJson: profile.metadataJson,
  }
}

function normalizeHistoryItems(items: HistoryItem[] | null | undefined): HistoryItem[] {
  return (items ?? []).map(normalizeHistoryItem)
}

function normalizeHistoryItem(item: HistoryItem): HistoryItem {
  return {
    workspaceId: item.workspaceId || localWorkspaceId,
    id: item.id,
    serverId: item.serverId || '',
    serverName: item.serverName || item.serverAddress,
    serverAddress: item.serverAddress,
    serviceName: item.serviceName,
    methodName: item.methodName,
    fullMethod: item.fullMethod,
    requestJson: item.requestJson || '{}',
    requestMetadataJson: item.requestMetadataJson || '{}',
    responseJson: item.responseJson || '{}',
    statusCode: item.statusCode,
    statusMessage: item.statusMessage || '',
    durationMs: Number(item.durationMs) || 0,
    error: item.error || '',
    createdAt: item.createdAt,
  }
}

function findMethodByFullName(services: GrpcService[], fullName: string): GrpcMethod | null {
  for (const service of services) {
    const method = service.methods.find((candidate) => candidate.fullName === fullName)
    if (method) return method
  }
  return null
}

function metadataRowsFromJson(metadataJson: string): MetadataEntry[] {
  try {
    const parsed = JSON.parse(metadataJson || '{}')
    if (!parsed || Array.isArray(parsed) || typeof parsed !== 'object') return []
    return Object.entries(parsed).map(([key, value]) => ({
      key,
      value: typeof value === 'string' ? value : String(value),
      enabled: true,
    }))
  } catch {
    return []
  }
}

function itemToResponse(item: HistoryItem): GrpcResponse {
  return {
    ok: item.statusCode === 'OK',
    statusCode: item.statusCode,
    statusMessage: item.statusMessage,
    durationMs: item.durationMs,
    bodyJson: item.responseJson || '{}',
    error: item.error,
  }
}

function normalizeCollections(collections: Collection[] | null | undefined): Collection[] {
  return (collections ?? []).map(normalizeCollection)
}

function normalizeCollection(collection: Collection): Collection {
  return {
    workspaceId: collection.workspaceId || localWorkspaceId,
    id: collection.id,
    name: collection.name,
    description: collection.description || '',
    requests: (collection.requests ?? []).map(normalizeCollectionRequest),
    createdAt: collection.createdAt || '',
    updatedAt: collection.updatedAt || '',
  }
}

function normalizeCollectionRequest(request: CollectionRequest): CollectionRequest {
  return {
    workspaceId: request.workspaceId || localWorkspaceId,
    id: request.id,
    collectionId: request.collectionId,
    name: request.name,
    serverId: request.serverId || '',
    serverName: request.serverName || request.serverAddress,
    serverAddress: request.serverAddress || '',
    serviceName: request.serviceName || '',
    methodName: request.methodName || '',
    fullMethod: request.fullMethod,
    requestJson: request.requestJson || '{}',
    requestMetadataJson: request.requestMetadataJson || '{}',
    createdAt: request.createdAt || '',
    updatedAt: request.updatedAt || '',
  }
}

import {beforeEach, describe, expect, it, vi} from 'vitest'
import {createPinia, setActivePinia} from 'pinia'
import {useGrpcClientStore} from './grpcClientStore'
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
import type {GrpcMethod} from '../types/grpc'

vi.mock('../../wailsjs/go/main/App', () => ({
  ClearHistory: vi.fn(),
  Connect: vi.fn(),
  CreateCollection: vi.fn(),
  CreateCollectionRequest: vi.fn(),
  CreateHistoryItem: vi.fn(),
  CreateServerProfile: vi.fn(),
  DeleteCollection: vi.fn(),
  DeleteCollectionRequest: vi.fn(),
  DeleteHistoryItem: vi.fn(),
  DeleteServerProfile: vi.fn(),
  Disconnect: vi.fn(),
  ExportWorkspace: vi.fn(),
  ImportWorkspace: vi.fn(),
  Invoke: vi.fn(),
  ListCollections: vi.fn(),
  ListHistoryItems: vi.fn(),
  ListServerProfiles: vi.fn(),
  UpdateCollection: vi.fn(),
  UpdateCollectionRequest: vi.fn(),
  UpdateServerProfile: vi.fn(),
}))

const unaryMethod: GrpcMethod = {
  serviceName: 'grpc.testing.TestService',
  methodName: 'EmptyCall',
  fullName: '/grpc.testing.TestService/EmptyCall',
  requestType: 'grpc.testing.Empty',
  responseType: 'grpc.testing.Empty',
  clientStreaming: false,
  serverStreaming: false,
  requestFields: [],
}

describe('grpcClientStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.mocked(ClearHistory).mockReset()
    vi.mocked(Connect).mockReset()
    vi.mocked(CreateCollection).mockReset()
    vi.mocked(CreateCollectionRequest).mockReset()
    vi.mocked(CreateHistoryItem).mockReset()
    vi.mocked(CreateServerProfile).mockReset()
    vi.mocked(DeleteCollection).mockReset()
    vi.mocked(DeleteCollectionRequest).mockReset()
    vi.mocked(DeleteHistoryItem).mockReset()
    vi.mocked(DeleteServerProfile).mockReset()
    vi.mocked(Disconnect).mockReset()
    vi.mocked(ExportWorkspace).mockReset()
    vi.mocked(ImportWorkspace).mockReset()
    vi.mocked(Invoke).mockReset()
    vi.mocked(ListCollections).mockReset()
    vi.mocked(ListHistoryItems).mockReset()
    vi.mocked(ListServerProfiles).mockReset()
    vi.mocked(UpdateCollection).mockReset()
    vi.mocked(UpdateCollectionRequest).mockReset()
    vi.mocked(UpdateServerProfile).mockReset()
    vi.mocked(CreateHistoryItem).mockImplementation(async (request: any) => ({
      workspaceId: 'local',
      id: 'history-id',
      createdAt: '2026-06-18T20:00:00Z',
      ...request,
    }))
    vi.mocked(CreateCollection).mockImplementation(async (request: any) => ({
      workspaceId: 'local',
      id: 'collection-id',
      requests: [],
      createdAt: '2026-06-19T07:00:00Z',
      updatedAt: '2026-06-19T07:00:00Z',
      ...request,
    }))
    vi.mocked(CreateCollectionRequest).mockImplementation(async (request: any) => ({
      workspaceId: 'local',
      id: 'collection-request-id',
      createdAt: '2026-06-19T07:01:00Z',
      updatedAt: '2026-06-19T07:01:00Z',
      ...request,
    }))
    vi.mocked(ExportWorkspace).mockResolvedValue({
      path: '/tmp/protodesk-workspace.json',
      serverCount: 1,
      collectionCount: 1,
      savedRequestCount: 2,
    } as any)
    vi.mocked(ImportWorkspace).mockResolvedValue({
      path: '/tmp/protodesk-workspace.json',
      serverCount: 1,
      collectionCount: 1,
      savedRequestCount: 2,
    } as any)
  })

  it('starts disconnected', () => {
    const store = useGrpcClientStore()

    expect(store.connection.state).toBe('disconnected')
    expect(store.status.message).toBe('Disconnected')
    expect(store.services).toEqual([])
    expect(store.canInvoke).toBe(false)
  })

  it('updates connection settings and connects with reflected services', async () => {
    vi.mocked(Connect).mockResolvedValue({
      state: 'connected',
      services: [{name: 'grpc.testing.TestService', methods: [unaryMethod]}],
    } as any)
    const store = useGrpcClientStore()

    store.setServerAddress('localhost:50051')
    store.setTlsEnabled(true)
    store.setReflectionEnabled(false)
    await store.connect()

    expect(Connect).toHaveBeenCalledWith({
      serverAddress: 'localhost:50051',
      tlsEnabled: true,
      reflectionEnabled: false,
      protoFiles: [],
      protoFolders: [],
      metadata: {},
    })
    expect(store.connection.state).toBe('connected')
    expect(store.services[0].methods[0].fullName).toBe(unaryMethod.fullName)
  })

  it('blocks invalid server addresses before calling backend', async () => {
    const store = useGrpcClientStore()

    store.setServerAddress('http://localhost:50051')
    await store.connect()

    expect(Connect).not.toHaveBeenCalled()
    expect(store.connection.state).toBe('failed')
    expect(store.connection.error).toContain('must not include a protocol prefix')
  })

  it('loads persisted server profiles', async () => {
    vi.mocked(ListServerProfiles).mockResolvedValue([
      {
        workspaceId: 'local',
        id: 'persisted',
        name: 'Persisted',
        address: 'persisted.example.com:443',
        tlsEnabled: true,
        reflectionEnabled: false,
        protoFiles: ['/workspace/protos/payments.proto'],
        protoFolders: ['/workspace/protos'],
        metadataJson: '{"x-team":"payments"}',
      },
    ] as any)
    const store = useGrpcClientStore()

    await store.loadServerProfiles()

    expect(ListServerProfiles).toHaveBeenCalled()
    expect(store.serverProfiles).toHaveLength(1)
    expect(store.selectedServerId).toBe('persisted')
    expect(store.connection.serverAddress).toBe('persisted.example.com:443')
    expect(store.connection.tlsEnabled).toBe(true)
  })

  it('uses default local server profile when persistence is empty', async () => {
    vi.mocked(ListServerProfiles).mockResolvedValue([])
    const store = useGrpcClientStore()

    await store.loadServerProfiles()

    expect(store.serverProfiles[0].workspaceId).toBe('local')
    expect(store.serverProfiles[0].id).toBe('local-default')
    expect(store.connection.serverAddress).toBe('localhost:50051')
  })

  it('creates, updates, selects, and deletes server profiles', async () => {
    vi.mocked(CreateServerProfile).mockResolvedValue({
      workspaceId: 'local',
      id: 'staging-id',
      name: 'Staging',
      address: 'staging.example.com:443',
      tlsEnabled: true,
      reflectionEnabled: true,
      protoFiles: ['/workspace/protos/payments.proto'],
      protoFolders: ['/workspace/protos'],
      metadataJson: '{"x-team":"payments"}',
    } as any)
    vi.mocked(UpdateServerProfile).mockResolvedValue({
      workspaceId: 'local',
      id: 'staging-id',
      name: 'Staging API',
      address: 'api.staging.example.com:443',
      tlsEnabled: true,
      reflectionEnabled: false,
      protoFiles: ['/workspace/protos/payments.proto'],
      protoFolders: ['/workspace/protos', '/workspace/vendor'],
      metadataJson: '{"x-team":"platform"}',
    } as any)
    vi.mocked(DeleteServerProfile).mockResolvedValue()
    const store = useGrpcClientStore()

    await store.createServerProfile({
      name: 'Staging',
      address: 'staging.example.com:443',
      tlsEnabled: true,
      reflectionEnabled: true,
      protoFiles: ['/workspace/protos/payments.proto'],
      protoFolders: ['/workspace/protos'],
      metadataJson: '{"x-team":"payments"}',
    })

    const created = store.serverProfiles.find((server) => server.name === 'Staging')
    expect(created).toBeTruthy()
    expect(store.selectedServerId).toBe(created?.id)
    expect(store.connection.serverAddress).toBe('staging.example.com:443')
    expect(store.connection.tlsEnabled).toBe(true)
    expect(created?.protoFiles).toEqual(['/workspace/protos/payments.proto'])
    expect(created?.metadataJson).toBe('{"x-team":"payments"}')
    expect(CreateServerProfile).toHaveBeenCalledWith({
      name: 'Staging',
      address: 'staging.example.com:443',
      tlsEnabled: true,
      reflectionEnabled: true,
      protoFiles: ['/workspace/protos/payments.proto'],
      protoFolders: ['/workspace/protos'],
      metadataJson: '{"x-team":"payments"}',
    })

    await store.updateServerProfile(created!.id, {
      name: 'Staging API',
      address: 'api.staging.example.com:443',
      tlsEnabled: true,
      reflectionEnabled: false,
      protoFolders: ['/workspace/protos', '/workspace/vendor'],
      metadataJson: '{"x-team":"platform"}',
    })

    expect(store.selectedServer?.name).toBe('Staging API')
    expect(store.connection.serverAddress).toBe('api.staging.example.com:443')
    expect(store.connection.reflectionEnabled).toBe(false)
    expect(store.selectedServer?.protoFolders).toEqual(['/workspace/protos', '/workspace/vendor'])

    await store.deleteServerProfile(created!.id)
    expect(store.serverProfiles.some((server) => server.id === created!.id)).toBe(false)
    expect(store.selectedServerId).toBe('')
    expect(store.connection.serverAddress).toBe('')
    expect(DeleteServerProfile).toHaveBeenCalledWith(created!.id)
  })

  it('does not mutate server profiles when saving fails', async () => {
    vi.mocked(CreateServerProfile).mockRejectedValue(new Error('disk full'))
    const store = useGrpcClientStore()

    await store.createServerProfile({
      name: 'Broken',
      address: 'broken.example.com:443',
      tlsEnabled: true,
      reflectionEnabled: true,
      protoFiles: [],
      protoFolders: [],
      metadataJson: '{}',
    })

    expect(store.serverProfiles).toHaveLength(1)
    expect(store.serverProfiles[0].id).toBe('local-default')
    expect(store.status.level).toBe('error')
    expect(store.status.message).toContain('Could not save')
  })

  it('keeps reflection unavailable as connected warning state', async () => {
    vi.mocked(Connect).mockResolvedValue({
      state: 'connected',
      services: [],
      error: 'server reflection is unavailable',
      reflectionUnavailable: true,
    } as any)
    const store = useGrpcClientStore()

    store.setServerAddress('localhost:50051')
    await store.connect()

    expect(store.connection.state).toBe('connected')
    expect(store.connection.reflectionUnavailable).toBe(true)
    expect(store.status.level).toBe('warning')
  })

  it('sends selected proto sources and reports reflection fallback', async () => {
    vi.mocked(Connect).mockResolvedValue({
      state: 'connected',
      services: [{name: 'protoonly.TestService', methods: [unaryMethod]}],
      descriptorSource: 'proto',
      reflectionUnavailable: true,
      error: 'server reflection is unavailable',
    } as any)
    const store = useGrpcClientStore()
    store.serverProfiles[0].protoFiles = ['/workspace/protos/service.proto']
    store.serverProfiles[0].protoFolders = ['/workspace/protos']

    await store.connect()

    expect(Connect).toHaveBeenCalledWith(expect.objectContaining({
      protoFiles: ['/workspace/protos/service.proto'],
      protoFolders: ['/workspace/protos'],
    }))
    expect(store.connection.descriptorSource).toBe('proto')
    expect(store.services).toHaveLength(1)
    expect(store.status.message).toContain('using proto files')
    expect(store.status.level).toBe('warning')
  })

  it('keeps proto compilation failures as connected warnings', async () => {
    vi.mocked(Connect).mockResolvedValue({
      state: 'connected',
      services: [],
      descriptorSource: 'none',
      protoSourceError: 'invalid.proto: unexpected EOF',
    } as any)
    const store = useGrpcClientStore()

    await store.connect()

    expect(store.connection.state).toBe('connected')
    expect(store.connection.protoSourceError).toContain('unexpected EOF')
    expect(store.status.level).toBe('warning')
    expect(store.status.message).toContain('proto sources unavailable')
  })

  it('blocks invalid server metadata before connecting', async () => {
    const store = useGrpcClientStore()
    store.serverProfiles[0].metadataJson = '{"authorization": 123}'

    await store.connect()

    expect(Connect).not.toHaveBeenCalled()
    expect(store.connection.state).toBe('failed')
    expect(store.connection.error).toContain('must be a string')
  })

  it('selects a method, clears response, and resets request JSON', () => {
    const store = useGrpcClientStore()
    store.response = {ok: true, statusCode: 'OK', durationMs: 1, bodyJson: '{}'}

    store.selectMethod(unaryMethod)

    expect(store.selectedMethod?.fullName).toBe(unaryMethod.fullName)
    expect(store.request.bodyJson).toBe('{}')
    expect(store.response).toBeNull()
    expect(store.status.message).toContain('selected')
  })

  it('blocks invoke when request JSON is invalid', async () => {
    const store = useGrpcClientStore()
    store.connection.state = 'connected'
    store.selectMethod(unaryMethod)
    store.setRequestBody('{')

    await store.invoke()

    expect(Invoke).not.toHaveBeenCalled()
    expect(CreateHistoryItem).not.toHaveBeenCalled()
    expect(store.request.validationError).toContain('Invalid JSON request body')
    expect(store.status.level).toBe('error')
  })

  it('records successful invocation history', async () => {
    vi.mocked(Invoke).mockResolvedValue({
      ok: true,
      statusCode: 'OK',
      durationMs: 12,
      bodyJson: '{"ok":true}',
    })
    const store = useGrpcClientStore()
    store.connection.state = 'connected'
    store.connection.serverAddress = 'localhost:50051'
    store.selectMethod(unaryMethod)

    await store.invoke()

    expect(CreateHistoryItem).toHaveBeenCalledWith(expect.objectContaining({
      serverAddress: 'localhost:50051',
      serviceName: unaryMethod.serviceName,
      methodName: unaryMethod.methodName,
      fullMethod: unaryMethod.fullName,
      requestJson: '{}',
      responseJson: '{"ok":true}',
      statusCode: 'OK',
      durationMs: 12,
    }))
    expect(store.historyItems[0].id).toBe('history-id')
  })

  it('records unary error responses in history', async () => {
    vi.mocked(Invoke).mockResolvedValue({
      ok: false,
      statusCode: 'NOT_FOUND',
      statusMessage: 'missing',
      durationMs: 6,
      bodyJson: '{}',
      error: 'tenant not found',
    })
    const store = useGrpcClientStore()
    store.connection.state = 'connected'
    store.connection.serverAddress = 'localhost:50051'
    store.selectMethod(unaryMethod)

    await store.invoke()

    expect(CreateHistoryItem).toHaveBeenCalledWith(expect.objectContaining({
      statusCode: 'NOT_FOUND',
      statusMessage: 'missing',
      error: 'tenant not found',
    }))
    expect(store.status.level).toBe('error')
  })

  it('sends only enabled non-empty metadata rows', async () => {
    vi.mocked(Invoke).mockResolvedValue({
      ok: true,
      statusCode: 'OK',
      durationMs: 12,
      bodyJson: '{}',
    })
    const store = useGrpcClientStore()
    store.connection.state = 'connected'
    store.connection.serverAddress = 'localhost:50051'
    store.selectMethod(unaryMethod)
    store.addMetadataRow()
    store.updateMetadataEntry(0, {key: 'authorization', value: 'Bearer test', enabled: true})
    store.addMetadataRow()
    store.updateMetadataEntry(1, {key: 'x-disabled', value: 'nope', enabled: false})
    store.addMetadataRow()
    store.updateMetadataEntry(2, {key: '', value: 'empty', enabled: true})

    await store.invoke()

    expect(Invoke).toHaveBeenCalledWith(expect.objectContaining({
      metadata: {authorization: 'Bearer test'},
    }))
    expect(store.response?.ok).toBe(true)
    expect(store.status.message).toContain('OK')
  })

  it('merges server metadata into invocation metadata with request rows taking precedence', async () => {
    vi.mocked(Invoke).mockResolvedValue({
      ok: true,
      statusCode: 'OK',
      durationMs: 9,
      bodyJson: '{}',
    })
    const store = useGrpcClientStore()
    store.connection.state = 'connected'
    store.connection.serverAddress = 'localhost:50051'
    store.serverProfiles[0].metadataJson = '{"authorization":"Bearer server","x-server":"yes"}'
    store.selectMethod(unaryMethod)
    store.addMetadataRow()
    store.updateMetadataEntry(0, {key: 'authorization', value: 'Bearer request', enabled: true})

    await store.invoke()

    expect(Invoke).toHaveBeenCalledWith(expect.objectContaining({
      metadata: {
        authorization: 'Bearer request',
        'x-server': 'yes',
      },
    }))
  })

  it('loads, deletes, clears, and restores requests from history', async () => {
    vi.mocked(ListHistoryItems).mockResolvedValue([
      {
        workspaceId: 'local',
        id: 'history-1',
        serverId: 'local-default',
        serverName: 'Local gRPC',
        serverAddress: 'localhost:50051',
        serviceName: unaryMethod.serviceName,
        methodName: unaryMethod.methodName,
        fullMethod: unaryMethod.fullName,
        requestJson: '{"name":"demo"}',
        requestMetadataJson: '{"authorization":"Bearer test"}',
        responseJson: '{"ok":true}',
        statusCode: 'OK',
        durationMs: 3,
        createdAt: '2026-06-18T20:00:00Z',
      },
    ] as any)
    vi.mocked(DeleteHistoryItem).mockResolvedValue()
    vi.mocked(ClearHistory).mockResolvedValue()
    const store = useGrpcClientStore()
    store.services = [{name: unaryMethod.serviceName, methods: [unaryMethod]}]

    await store.openHistoryModal()
    expect(store.historyModalOpen).toBe(true)
    expect(store.selectedHistoryItem?.id).toBe('history-1')

    store.loadHistoryRequest(store.selectedHistoryItem!)
    expect(store.historyModalOpen).toBe(false)
    expect(store.selectedMethod?.fullName).toBe(unaryMethod.fullName)
    expect(store.request.bodyJson).toBe('{"name":"demo"}')
    expect(store.request.metadata).toEqual([{key: 'authorization', value: 'Bearer test', enabled: true}])
    expect(store.response?.bodyJson).toBe('{"ok":true}')

    await store.deleteHistoryItem('history-1')
    expect(DeleteHistoryItem).toHaveBeenCalledWith('history-1')
    expect(store.historyItems).toEqual([])

    store.historyItems = [{
      workspaceId: 'local',
      id: 'history-2',
      serverId: 'local-default',
      serverName: 'Local gRPC',
      serverAddress: 'localhost:50051',
      serviceName: unaryMethod.serviceName,
      methodName: unaryMethod.methodName,
      fullMethod: unaryMethod.fullName,
      requestJson: '{}',
      requestMetadataJson: '{}',
      responseJson: '{}',
      statusCode: 'OK',
      durationMs: 1,
      createdAt: '2026-06-18T20:01:00Z',
    }]
    await store.clearHistory()
    expect(ClearHistory).toHaveBeenCalled()
    expect(store.historyItems).toEqual([])
  })

  it('loads collections and saves the current request', async () => {
    vi.mocked(ListCollections).mockResolvedValue([])
    const store = useGrpcClientStore()
    store.connection.serverAddress = 'localhost:50051'
    store.selectMethod(unaryMethod)
    store.setRequestBody('{"name":"demo"}')
    store.addMetadataRow()
    store.updateMetadataEntry(0, {key: 'authorization', value: 'Bearer test', enabled: true})

    await store.openCollectionsModal()
    await store.saveCurrentRequestToCollection('', 'Demo request')

    expect(CreateCollection).toHaveBeenCalledWith({name: 'Personal', description: ''})
    expect(CreateCollectionRequest).toHaveBeenCalledWith(expect.objectContaining({
      collectionId: 'collection-id',
      name: 'Demo request',
      fullMethod: unaryMethod.fullName,
      requestJson: '{"name":"demo"}',
      requestMetadataJson: '{\n  "authorization": "Bearer test"\n}',
    }))
    expect(store.collections[0].requests[0].name).toBe('Demo request')
  })

  it('saves a history item into a collection and loads saved requests', async () => {
    const store = useGrpcClientStore()
    const historyItem = {
      workspaceId: 'local',
      id: 'history-1',
      serverId: 'local-default',
      serverName: 'Local gRPC',
      serverAddress: 'localhost:50051',
      serviceName: unaryMethod.serviceName,
      methodName: unaryMethod.methodName,
      fullMethod: unaryMethod.fullName,
      requestJson: '{"from":"history"}',
      requestMetadataJson: '{"x-history":"yes"}',
      responseJson: '{}',
      statusCode: 'OK',
      durationMs: 1,
      createdAt: '2026-06-19T07:00:00Z',
    }
    store.services = [{name: unaryMethod.serviceName, methods: [unaryMethod]}]

    await store.saveHistoryItemToCollection(historyItem, '', 'From history')
    const saved = store.collections[0].requests[0]
    store.loadCollectionRequest(saved)

    expect(CreateCollectionRequest).toHaveBeenCalledWith(expect.objectContaining({
      name: 'From history',
      requestJson: '{"from":"history"}',
      requestMetadataJson: '{"x-history":"yes"}',
    }))
    expect(store.selectedMethod?.fullName).toBe(unaryMethod.fullName)
    expect(store.request.bodyJson).toBe('{"from":"history"}')
    expect(store.request.metadata).toEqual([{key: 'x-history', value: 'yes', enabled: true}])
  })

  it('deletes collections and saved requests', async () => {
    vi.mocked(DeleteCollection).mockResolvedValue()
    vi.mocked(DeleteCollectionRequest).mockResolvedValue()
    const store = useGrpcClientStore()
    store.collections = [{
      workspaceId: 'local',
      id: 'collection-id',
      name: 'Personal',
      description: '',
      createdAt: '',
      updatedAt: '',
      requests: [{
        workspaceId: 'local',
        id: 'request-id',
        collectionId: 'collection-id',
        name: 'Saved',
        serverId: '',
        serverName: '',
        serverAddress: 'localhost:50051',
        serviceName: unaryMethod.serviceName,
        methodName: unaryMethod.methodName,
        fullMethod: unaryMethod.fullName,
        requestJson: '{}',
        requestMetadataJson: '{}',
        createdAt: '',
        updatedAt: '',
      }],
    }]
    store.selectedCollectionId = 'collection-id'
    store.selectedCollectionRequestId = 'request-id'

    await store.deleteCollectionRequest('request-id')
    expect(store.collections[0].requests).toEqual([])

    await store.deleteCollection('collection-id')
    expect(store.collections).toEqual([])
  })

  it('exports and imports workspace data', async () => {
    vi.mocked(ListServerProfiles).mockResolvedValue([])
    vi.mocked(ListCollections).mockResolvedValue([])
    const store = useGrpcClientStore()

    store.openWorkspaceModal()
    expect(store.workspaceModalOpen).toBe(true)

    await store.exportWorkspace()
    expect(ExportWorkspace).toHaveBeenCalled()
    expect(store.workspaceTransferResult?.savedRequestCount).toBe(2)
    expect(store.status.message).toContain('Exported workspace')

    await store.importWorkspace()
    expect(ImportWorkspace).toHaveBeenCalled()
    expect(ListServerProfiles).toHaveBeenCalled()
    expect(ListCollections).toHaveBeenCalled()
    expect(store.status.message).toContain('Imported workspace')
  })

  it('disconnect clears selected state', async () => {
    vi.mocked(Disconnect).mockResolvedValue()
    const store = useGrpcClientStore()
    store.connection.state = 'connected'
    store.services = [{name: 'grpc.testing.TestService', methods: [unaryMethod]}]
    store.selectMethod(unaryMethod)

    await store.disconnect()

    expect(Disconnect).toHaveBeenCalled()
    expect(store.connection.state).toBe('disconnected')
    expect(store.selectedMethod).toBeNull()
    expect(store.services).toEqual([])
  })
})

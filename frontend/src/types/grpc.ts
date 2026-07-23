export type ConnectionState =
  | 'idle'
  | 'connecting'
  | 'connected'
  | 'failed'
  | 'disconnected'

export type StatusLevel = 'idle' | 'info' | 'success' | 'warning' | 'error'

export interface GrpcMethod {
  serviceName: string
  methodName: string
  fullName: string
  requestType: string
  responseType: string
  clientStreaming: boolean
  serverStreaming: boolean
  requestFields: GrpcField[]
  messageTypes?: Record<string, GrpcMessageType>
}

export interface GrpcMessageType {
  fields: GrpcField[]
}

export interface GrpcField {
  name: string
  jsonName: string
  type: string
  repeated: boolean
  map: boolean
  messageType?: string
  enumValues?: string[]
}

export interface GrpcService {
  name: string
  methods: GrpcMethod[]
}

export interface MetadataEntry {
  key: string
  value: string
  enabled: boolean
}

export interface CallOptions {
  timeoutMs: number
  authority?: string
}

export interface GrpcResponse {
  ok: boolean
  statusCode: string
  statusMessage?: string
  durationMs: number
  bodyJson?: string
  responseMetadata?: Record<string, string>
  error?: string
}

export interface ConnectionStateData {
  state: ConnectionState
  serverAddress: string
  tlsEnabled: boolean
  reflectionEnabled: boolean
  error?: string
  reflectionUnavailable?: boolean
  descriptorSource?: 'reflection' | 'proto' | 'none'
  protoSourceError?: string
}

export interface GrpcRequestDraft {
  bodyJson: string
  metadata: MetadataEntry[]
  options: CallOptions
  validationError?: string
}

export interface StatusMessage {
  level: StatusLevel
  message: string
}

export interface ServerProfile {
  workspaceId: string
  id: string
  name: string
  address: string
  tlsEnabled: boolean
  reflectionEnabled: boolean
  protoFiles: string[]
  protoFolders: string[]
  metadataJson: string
}

export interface HistoryItem {
  workspaceId: string
  id: string
  serverId: string
  serverName: string
  serverAddress: string
  serviceName: string
  methodName: string
  fullMethod: string
  requestJson: string
  requestMetadataJson: string
  responseJson: string
  statusCode: string
  statusMessage?: string
  durationMs: number
  error?: string
  createdAt: string
}

export interface Collection {
  workspaceId: string
  id: string
  name: string
  description: string
  requests: CollectionRequest[]
  createdAt: string
  updatedAt: string
}

export interface CollectionRequest {
  workspaceId: string
  id: string
  collectionId: string
  name: string
  serverId: string
  serverName: string
  serverAddress: string
  serviceName: string
  methodName: string
  fullMethod: string
  requestJson: string
  requestMetadataJson: string
  createdAt: string
  updatedAt: string
}

export interface WorkspaceTransferResult {
  path?: string
  serverCount: number
  collectionCount: number
  savedRequestCount: number
  skipped?: boolean
}

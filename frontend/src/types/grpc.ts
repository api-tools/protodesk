export interface GRPCRequest {
  methodName: string
  payload: any
  metadata?: Record<string, string>
}

export interface GRPCResponse {
  data: any
  metadata?: Record<string, string>
  error?: string
}

export interface GRPCStream {
  id: string
  type: 'client' | 'server' | 'bidirectional'
  status: 'active' | 'closed' | 'error'
  error?: string
}

export interface GRPCMetadata {
  key: string
  value: string[]
  isBinary: boolean
}

package main

type ConnectRequest struct {
	ServerAddress     string            `json:"serverAddress"`
	TLSEnabled        bool              `json:"tlsEnabled"`
	ReflectionEnabled bool              `json:"reflectionEnabled"`
	ProtoFiles        []string          `json:"protoFiles"`
	ProtoFolders      []string          `json:"protoFolders"`
	Metadata          map[string]string `json:"metadata"`
}

type PickProtoFilesResponse struct {
	Paths []string `json:"paths"`
}

type PickProtoFolderResponse struct {
	Folder     string   `json:"folder"`
	ProtoFiles []string `json:"protoFiles"`
}

type ValidateProtoSourcesRequest struct {
	ProtoFiles   []string `json:"protoFiles"`
	ProtoFolders []string `json:"protoFolders"`
}

type ValidateProtoSourcesResponse struct {
	Valid     bool     `json:"valid"`
	FileCount int      `json:"fileCount"`
	Errors    []string `json:"errors,omitempty"`
}

type ServerProfile struct {
	WorkspaceID       string   `json:"workspaceId"`
	ID                string   `json:"id"`
	Name              string   `json:"name"`
	Address           string   `json:"address"`
	TLSEnabled        bool     `json:"tlsEnabled"`
	ReflectionEnabled bool     `json:"reflectionEnabled"`
	ProtoFiles        []string `json:"protoFiles"`
	ProtoFolders      []string `json:"protoFolders"`
	MetadataJSON      string   `json:"metadataJson"`
}

type SaveServerProfileRequest struct {
	Name              string   `json:"name"`
	Address           string   `json:"address"`
	TLSEnabled        bool     `json:"tlsEnabled"`
	ReflectionEnabled bool     `json:"reflectionEnabled"`
	ProtoFiles        []string `json:"protoFiles"`
	ProtoFolders      []string `json:"protoFolders"`
	MetadataJSON      string   `json:"metadataJson"`
}

type HistoryItem struct {
	WorkspaceID         string `json:"workspaceId"`
	ID                  string `json:"id"`
	ServerID            string `json:"serverId"`
	ServerName          string `json:"serverName"`
	ServerAddress       string `json:"serverAddress"`
	ServiceName         string `json:"serviceName"`
	MethodName          string `json:"methodName"`
	FullMethod          string `json:"fullMethod"`
	RequestJSON         string `json:"requestJson"`
	RequestMetadataJSON string `json:"requestMetadataJson"`
	ResponseJSON        string `json:"responseJson"`
	StatusCode          string `json:"statusCode"`
	StatusMessage       string `json:"statusMessage,omitempty"`
	DurationMs          int64  `json:"durationMs"`
	Error               string `json:"error,omitempty"`
	CreatedAt           string `json:"createdAt"`
}

type SaveHistoryItemRequest struct {
	ServerID            string `json:"serverId"`
	ServerName          string `json:"serverName"`
	ServerAddress       string `json:"serverAddress"`
	ServiceName         string `json:"serviceName"`
	MethodName          string `json:"methodName"`
	FullMethod          string `json:"fullMethod"`
	RequestJSON         string `json:"requestJson"`
	RequestMetadataJSON string `json:"requestMetadataJson"`
	ResponseJSON        string `json:"responseJson"`
	StatusCode          string `json:"statusCode"`
	StatusMessage       string `json:"statusMessage,omitempty"`
	DurationMs          int64  `json:"durationMs"`
	Error               string `json:"error,omitempty"`
}

type Collection struct {
	WorkspaceID string              `json:"workspaceId"`
	ID          string              `json:"id"`
	Name        string              `json:"name"`
	Description string              `json:"description"`
	Requests    []CollectionRequest `json:"requests"`
	CreatedAt   string              `json:"createdAt"`
	UpdatedAt   string              `json:"updatedAt"`
}

type SaveCollectionRequest struct {
	Name        string `json:"name"`
	Description string `json:"description"`
}

type CollectionRequest struct {
	WorkspaceID         string `json:"workspaceId"`
	ID                  string `json:"id"`
	CollectionID        string `json:"collectionId"`
	Name                string `json:"name"`
	ServerID            string `json:"serverId"`
	ServerName          string `json:"serverName"`
	ServerAddress       string `json:"serverAddress"`
	ServiceName         string `json:"serviceName"`
	MethodName          string `json:"methodName"`
	FullMethod          string `json:"fullMethod"`
	RequestJSON         string `json:"requestJson"`
	RequestMetadataJSON string `json:"requestMetadataJson"`
	CreatedAt           string `json:"createdAt"`
	UpdatedAt           string `json:"updatedAt"`
}

type SaveCollectionRequestItemRequest struct {
	CollectionID        string `json:"collectionId"`
	Name                string `json:"name"`
	ServerID            string `json:"serverId"`
	ServerName          string `json:"serverName"`
	ServerAddress       string `json:"serverAddress"`
	ServiceName         string `json:"serviceName"`
	MethodName          string `json:"methodName"`
	FullMethod          string `json:"fullMethod"`
	RequestJSON         string `json:"requestJson"`
	RequestMetadataJSON string `json:"requestMetadataJson"`
}

type WorkspaceExportFile struct {
	Version     int             `json:"version"`
	Kind        string          `json:"kind"`
	ExportedAt  string          `json:"exportedAt"`
	WorkspaceID string          `json:"workspaceId"`
	Servers     []ServerProfile `json:"servers"`
	Collections []Collection    `json:"collections"`
}

type WorkspaceTransferResult struct {
	Path              string `json:"path,omitempty"`
	ServerCount       int    `json:"serverCount"`
	CollectionCount   int    `json:"collectionCount"`
	SavedRequestCount int    `json:"savedRequestCount"`
	Skipped           bool   `json:"skipped,omitempty"`
}

type ConnectResponse struct {
	State                 string        `json:"state"`
	Services              []GrpcService `json:"services"`
	Error                 string        `json:"error,omitempty"`
	ReflectionUnavailable bool          `json:"reflectionUnavailable,omitempty"`
	DescriptorSource      string        `json:"descriptorSource,omitempty"`
	ProtoSourceError      string        `json:"protoSourceError,omitempty"`
}

type ListServicesResponse struct {
	Services []GrpcService `json:"services"`
}

type GrpcService struct {
	Name    string       `json:"name"`
	Methods []GrpcMethod `json:"methods"`
}

type GrpcMethod struct {
	ServiceName     string                     `json:"serviceName"`
	MethodName      string                     `json:"methodName"`
	FullName        string                     `json:"fullName"`
	RequestType     string                     `json:"requestType"`
	ResponseType    string                     `json:"responseType"`
	ClientStreaming bool                       `json:"clientStreaming"`
	ServerStreaming bool                       `json:"serverStreaming"`
	RequestFields   []GrpcField                `json:"requestFields"`
	MessageTypes    map[string]GrpcMessageType `json:"messageTypes,omitempty"`
}

type GrpcMessageType struct {
	Fields []GrpcField `json:"fields"`
}

type GrpcField struct {
	Name        string   `json:"name"`
	JSONName    string   `json:"jsonName"`
	Type        string   `json:"type"`
	Repeated    bool     `json:"repeated"`
	Map         bool     `json:"map"`
	MessageType string   `json:"messageType,omitempty"`
	EnumValues  []string `json:"enumValues,omitempty"`
}

type InvokeRequest struct {
	ServerAddress string            `json:"serverAddress"`
	FullMethod    string            `json:"fullMethod"`
	BodyJSON      string            `json:"bodyJson"`
	Metadata      map[string]string `json:"metadata"`
	TimeoutMs     int               `json:"timeoutMs"`
	Authority     string            `json:"authority,omitempty"`
}

type InvokeResponse struct {
	OK               bool              `json:"ok"`
	StatusCode       string            `json:"statusCode"`
	StatusMessage    string            `json:"statusMessage,omitempty"`
	DurationMs       int64             `json:"durationMs"`
	BodyJSON         string            `json:"bodyJson,omitempty"`
	ResponseMetadata map[string]string `json:"responseMetadata,omitempty"`
	Error            string            `json:"error,omitempty"`
}

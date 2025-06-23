package app

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"protodesk/pkg/models"
	"protodesk/pkg/models/proto"
	"protodesk/pkg/services"

	"github.com/jhump/protoreflect/desc"
	"github.com/jhump/protoreflect/desc/protoparse"
	"github.com/jhump/protoreflect/dynamic"
	"github.com/jhump/protoreflect/grpcreflect"
	"github.com/wailsapp/wails/v2/pkg/runtime"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
	reflectpb "google.golang.org/grpc/reflection/grpc_reflection_v1alpha"
	"google.golang.org/protobuf/encoding/prototext"
	goproto "google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/descriptorpb"
)

// App struct represents the main application
type App struct {
	ctx            context.Context
	profileManager *services.ServerProfileManager
	protoParser    *services.ProtoParser
}

// NewApp creates a new App application struct
func NewApp() *App {
	return &App{}
}

// Startup is called when the app starts. The context is saved
// so we can call the runtime methods
func (a *App) Startup(ctx context.Context) error {
	fmt.Println("[Startup] Startup called")
	a.ctx = ctx

	homeDir, err := os.UserHomeDir()
	if err != nil {
		fmt.Println("[Startup] Failed to get user home directory:", err)
		return fmt.Errorf("failed to get user home directory: %w", err)
	}
	fmt.Println("[Startup] Home directory:", homeDir)

	dataDir := filepath.Join(homeDir, ".protodesk")
	if err := os.MkdirAll(dataDir, 0755); err != nil {
		fmt.Println("[Startup] Failed to create data directory:", err)
		return fmt.Errorf("failed to create data directory: %w", err)
	}
	fmt.Println("[Startup] Data directory:", dataDir)

	store, err := services.NewSQLiteStore(dataDir)
	if err != nil {
		fmt.Println("[Startup] Failed to initialize server profile store:", err)
		return fmt.Errorf("failed to initialize server profile store: %w", err)
	}
	fmt.Println("[Startup] Server profile store initialized")

	// Detect and store well-known types
	wellKnownTypesManager := services.NewWellKnownTypesManager(store)
	if err := wellKnownTypesManager.DetectAndStoreWellKnownTypes(ctx); err != nil {
		fmt.Printf("[WARN] Failed to detect well-known types: %v\n", err)
	} else {
		fmt.Println("[Startup] Well-known types detected and stored.")
	}

	// Register well-known types with the protobuf global registry
	if err := RegisterWellKnownTypesFromDB(ctx, store); err != nil {
		fmt.Printf("[WARN] Failed to register well-known types: %v\n", err)
	} else {
		fmt.Println("[Startup] Well-known types registered with protobuf global registry.")
	}

	a.profileManager = services.NewServerProfileManager(store)
	fmt.Println("[Startup] profileManager initialized successfully")

	a.protoParser = services.NewProtoParser(store)
	fmt.Println("[Startup] protoParser initialized successfully")

	return nil
}

// CreateServerProfile creates a new server profile
func (a *App) CreateServerProfile(name string, host string, port int, enableTLS bool, certPath *string, useReflection bool, headers []models.Header) (*models.ServerProfile, error) {
	if a.profileManager == nil {
		return nil, fmt.Errorf("profileManager is not initialized (did Startup run successfully?)")
	}
	profile := models.NewServerProfile(name, host, port)
	profile.TLSEnabled = enableTLS
	profile.CertificatePath = certPath
	profile.UseReflection = useReflection
	profile.Headers = headers

	if err := profile.Validate(); err != nil {
		return nil, err
	}

	if err := a.profileManager.GetStore().Create(a.ctx, profile); err != nil {
		return nil, fmt.Errorf("failed to create server profile: %w", err)
	}

	return profile, nil
}

// GetServerProfile retrieves a server profile by ID
func (a *App) GetServerProfile(id string) (*models.ServerProfile, error) {
	return a.profileManager.GetStore().Get(a.ctx, id)
}

// ListServerProfiles returns all server profiles
func (a *App) ListServerProfiles() ([]*models.ServerProfile, error) {
	return a.profileManager.GetStore().List(a.ctx)
}

// UpdateServerProfile updates an existing server profile
func (a *App) UpdateServerProfile(profile *models.ServerProfile) error {
	if err := profile.Validate(); err != nil {
		return err
	}
	return a.profileManager.GetStore().Update(a.ctx, profile)
}

// DeleteServerProfile deletes a server profile by ID
func (a *App) DeleteServerProfile(id string) error {
	// Disconnect if connected
	if a.profileManager.IsConnected(id) {
		if err := a.profileManager.Disconnect(a.ctx, id); err != nil {
			return fmt.Errorf("failed to disconnect before deletion: %w", err)
		}
	}
	return a.profileManager.GetStore().Delete(a.ctx, id)
}

// ConnectToServer establishes a connection to a server profile
func (a *App) ConnectToServer(id string) error {
	return a.profileManager.Connect(a.ctx, id)
}

// DisconnectFromServer closes the connection to a server profile
func (a *App) DisconnectFromServer(id string) error {
	return a.profileManager.Disconnect(a.ctx, id)
}

// IsServerConnected checks if a server profile is currently connected
func (a *App) IsServerConnected(id string) bool {
	return a.profileManager.IsConnected(id)
}

// Shutdown handles cleanup when the application exits
func (a *App) Shutdown(ctx context.Context) {
	a.profileManager.DisconnectAll()
}

// Greet returns a greeting for the given name
func (a *App) Greet(name string) string {
	return fmt.Sprintf("Hello %s, It's show time!", name)
}

// SaveProtoDefinition saves a parsed proto definition to storage
func (a *App) SaveProtoDefinition(def *proto.ProtoDefinition) error {
	return a.profileManager.GetStore().CreateProtoDefinition(a.ctx, def)
}

// ListProtoDefinitionsByProfile lists proto definitions for a server profile
func (a *App) ListProtoDefinitionsByProfile(profileID string) ([]*proto.ProtoDefinition, error) {
	if a.ctx == nil {
		return nil, fmt.Errorf("context not initialized")
	}
	return a.profileManager.ListProtoDefinitionsByProfile(a.ctx, profileID)
}

// DeleteProtoDefinition deletes a proto definition by ID
func (a *App) DeleteProtoDefinition(id string) error {
	return a.profileManager.GetStore().DeleteProtoDefinition(a.ctx, id)
}

// ProtoFileImport represents a proto file to be imported
type ProtoFileImport struct {
	FilePath       string `json:"filePath"`
	Content        string `json:"content"`
	SelectedFolder string `json:"selectedFolder"`
}

// ImportProtoFilesFromFolder opens a folder picker, recursively finds all .proto files, and returns their paths and contents
func (a *App) ImportProtoFilesFromFolder() ([]ProtoFileImport, error) {
	if a.ctx == nil {
		return nil, fmt.Errorf("context not initialized")
	}
	// Open folder picker dialog
	folder, err := runtime.OpenDirectoryDialog(a.ctx, runtime.OpenDialogOptions{
		Title: "Select a folder containing proto files",
	})
	if err != nil {
		return nil, err
	}
	if folder == "" {
		return nil, nil // user cancelled
	}

	// Get the absolute path
	absPath, err := filepath.Abs(folder)
	if err != nil {
		return nil, fmt.Errorf("failed to get absolute path: %w", err)
	}
	fmt.Printf("[DEBUG] Selected folder: %s\n", absPath)

	var results []ProtoFileImport
	err = filepath.Walk(absPath, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		// Skip node_modules directory
		if info.IsDir() && info.Name() == "node_modules" {
			fmt.Printf("[DEBUG] Skipping node_modules directory: %s\n", path)
			return filepath.SkipDir
		}
		if !info.IsDir() && filepath.Ext(path) == ".proto" {
			fmt.Printf("[DEBUG] Found proto file: %s\n", path)
			content, readErr := os.ReadFile(path)
			if readErr != nil {
				return readErr
			}
			// Store the absolute path and selected folder
			results = append(results, ProtoFileImport{
				FilePath:       path,
				Content:        string(content),
				SelectedFolder: absPath,
			})
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	fmt.Printf("[DEBUG] Total proto files found: %d\n", len(results))
	return results, nil
}

// SelectProtoFolder opens a directory dialog and returns the selected folder path
func (a *App) SelectProtoFolder() (string, error) {
	if a.ctx == nil {
		return "", fmt.Errorf("context not initialized")
	}
	folder, err := runtime.OpenDirectoryDialog(a.ctx, runtime.OpenDialogOptions{
		Title: "Select a proto folder",
	})
	if err != nil {
		return "", err
	}
	return folder, nil
}

// ScanAndParseProtoPath scans a proto path, parses all .proto files, and stores results in the DB
func (a *App) ScanAndParseProtoPath(serverProfileId string, protoPathId string, path string) error {
	fmt.Printf("[DEBUG] Scanning proto path: %s\n", path)
	return a.protoParser.ScanAndParseProtoPath(a.ctx, serverProfileId, protoPathId, path)
}

// CreateProtoPath creates a proto path record in the database and links it to a server profile
func (a *App) CreateProtoPath(id, serverProfileId, path string) error {
	if a.profileManager == nil {
		return fmt.Errorf("profile manager not initialized; startup may not have run successfully")
	}
	fmt.Printf("[DEBUG] Creating proto path with ID: %s, ServerProfileID: %s, Path: %s\n", id, serverProfileId, path)

	// Calculate hash of all proto files in the directory
	hash, err := calculateProtoPathHash(path)
	if err != nil {
		return fmt.Errorf("failed to calculate proto path hash: %w", err)
	}

	protoPath := &proto.ProtoPath{
		ID:              id,
		ServerProfileID: serverProfileId,
		Path:            path,
		Hash:            hash,
		LastScanned:     time.Now(),
	}

	err = a.profileManager.GetStore().CreateProtoPath(context.Background(), protoPath)
	if err != nil {
		fmt.Printf("[ERROR] Failed to create proto path: %v\n", err)
		return err
	}
	fmt.Printf("[DEBUG] Successfully created proto path\n")

	// Parse proto files
	err = a.protoParser.ScanAndParseProtoPath(context.Background(), serverProfileId, id, path)
	if err != nil {
		fmt.Printf("[ERROR] Failed to parse proto files: %v\n", err)
		return err
	}

	// Preprocess proto definitions to remove self-imports (direct cycles)
	protoDefs, err := a.profileManager.ListProtoDefinitionsByProfile(context.Background(), serverProfileId)
	if err != nil {
		return err
	}
	for i, def := range protoDefs {
		lines := strings.Split(def.Content, "\n")
		var newLines []string
		for _, line := range lines {
			trimmed := strings.TrimSpace(line)
			if strings.HasPrefix(trimmed, "import ") && strings.Contains(trimmed, def.FilePath) {
				fmt.Printf("[WARN] Ignoring self-import in %s: %s\n", def.FilePath, trimmed)
				continue // skip this line
			}
			newLines = append(newLines, line)
		}
		protoDefs[i].Content = strings.Join(newLines, "\n")
	}

	return nil
}

// calculateProtoPathHash calculates a hash of all proto files in a directory
func calculateProtoPathHash(path string) (string, error) {
	var files []string
	err := filepath.Walk(path, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() && strings.HasSuffix(info.Name(), ".proto") {
			files = append(files, path)
		}
		return nil
	})
	if err != nil {
		return "", fmt.Errorf("failed to walk directory: %w", err)
	}

	// Sort files to ensure consistent hashing
	sort.Strings(files)

	// Create a hash of all file contents
	h := sha256.New()
	for _, file := range files {
		content, err := os.ReadFile(file)
		if err != nil {
			return "", fmt.Errorf("failed to read file %s: %w", file, err)
		}
		h.Write(content)
	}

	return hex.EncodeToString(h.Sum(nil)), nil
}

// ListProtoPathsByServer lists proto paths for a given server profile
func (a *App) ListProtoPathsByServer(serverID string) ([]*proto.ProtoPath, error) {
	if a.profileManager == nil {
		return nil, fmt.Errorf("profile manager not initialized; startup may not have run successfully")
	}
	return a.profileManager.GetStore().ListProtoPathsByServer(context.Background(), serverID)
}

// DeleteProtoPath deletes a proto path by its ID
func (a *App) DeleteProtoPath(id string) error {
	if a.profileManager == nil {
		return fmt.Errorf("profile manager not initialized; startup may not have run successfully")
	}
	return a.profileManager.GetStore().DeleteProtoPath(context.Background(), id)
}

// ConnectServer establishes a connection to the specified server profile
func (a *App) ConnectServer(ctx context.Context, profileID string) error {
	return a.profileManager.Connect(ctx, profileID)
}

// ListServerServices returns all services and their methods for a connected server using reflection
func (a *App) ListServerServices(profileID string) (map[string][]string, error) {
	if a.profileManager == nil {
		return nil, fmt.Errorf("profileManager is not initialized")
	}
	conn, err := a.profileManager.GetConnection(profileID)
	if err != nil {
		return nil, fmt.Errorf("no active connection for profile %s: %w", profileID, err)
	}
	return a.profileManager.GetGRPCClient().ListServicesAndMethods(conn)
}

// GetMethodInputDescriptor returns the input fields for a given service/method using reflection
func (a *App) GetMethodInputDescriptor(profileID, serviceName, methodName string) ([]services.FieldDescriptor, error) {
	if a.profileManager == nil {
		return nil, fmt.Errorf("profileManager is not initialized")
	}
	conn, err := a.profileManager.GetConnection(profileID)
	if err != nil {
		return nil, fmt.Errorf("no active connection for profile %s: %w", profileID, err)
	}
	return a.profileManager.GetGRPCClient().GetMethodInputDescriptor(conn, serviceName, methodName)
}

// SavePerRequestHeaders saves or updates per-request headers for a method
func (a *App) SavePerRequestHeaders(serverProfileID, serviceName, methodName, headersJSON string) error {
	h := &models.PerRequestHeaders{
		ServerProfileID: serverProfileID,
		ServiceName:     serviceName,
		MethodName:      methodName,
		HeadersJSON:     headersJSON,
	}
	return a.profileManager.GetStore().UpsertPerRequestHeaders(a.ctx, h)
}

// GetPerRequestHeaders retrieves per-request headers for a method
func (a *App) GetPerRequestHeaders(serverProfileID, serviceName, methodName string) (string, error) {
	h, err := a.profileManager.GetStore().GetPerRequestHeaders(a.ctx, serverProfileID, serviceName, methodName)
	if err != nil {
		return "", err
	}
	return h.HeadersJSON, nil
}

// CallGRPCMethod calls a gRPC method and returns the response as JSON
func (a *App) CallGRPCMethod(
	profileID string,
	serviceName string,
	methodName string,
	requestJSON string,
	headersJSON string,
) (string, error) {
	fmt.Printf("[DEBUG] CallGRPCMethod called with:\n  profileID: %s\n  serviceName: %s\n  methodName: %s\n  requestJSON: %s\n  headersJSON: %s\n", profileID, serviceName, methodName, requestJSON, headersJSON)
	// 0. Get server profile
	profile, err := a.profileManager.GetStore().Get(a.ctx, profileID)
	if err != nil {
		return "", fmt.Errorf("failed to get server profile: %w", err)
	}

	if !profile.UseReflection {
		fmt.Printf("[DEBUG] Using local proto definitions for server %s\n", profileID)
		ctx := context.Background()
		protoDefs, err := a.profileManager.GetStore().ListProtoDefinitionsByProfile(ctx, profileID)
		if err != nil {
			return "", fmt.Errorf("failed to list proto definitions: %w", err)
		}
		if len(protoDefs) == 0 {
			return "", fmt.Errorf("no proto definitions found for profile %s", profileID)
		}

		// Build a map of file path to content for the parser accessor
		fileContentMap := make(map[string]string)
		var entryFiles []string
		protoRoot := "/Users/l.chmielewski/Projects/proto/proto" // TODO: make this dynamic if needed
		for _, def := range protoDefs {
			rel, err := filepath.Rel(protoRoot, def.FilePath)
			if err != nil {
				rel = def.FilePath // fallback
			}
			rel = filepath.ToSlash(rel) // ensure forward slashes
			fileContentMap[rel] = def.Content
			entryFiles = append(entryFiles, rel)
		}
		fmt.Printf("[DEBUG] Entry files for proto parsing: %v\n", entryFiles)
		fmt.Printf("[DEBUG] fileContentMap keys: %v\n", func() []string {
			keys := make([]string, 0, len(fileContentMap))
			for k := range fileContentMap {
				keys = append(keys, k)
			}
			return keys
		}())

		// Add well-known types from the DB
		wellKnownTypes, err := a.profileManager.GetStore().ListWellKnownTypes(ctx)
		if err == nil {
			for _, wkt := range wellKnownTypes {
				fileContentMap[wkt.FilePath] = wkt.Content
			}
		}

		// Build a unique, cycle-free list of proto files to parse for the service/method
		visited := make(map[string]bool)
		var orderedFiles []string
		var dfs func(string, []string)
		dfs = func(file string, stack []string) {
			if visited[file] {
				return
			}
			for _, ancestor := range stack {
				if ancestor == file {
					fmt.Printf("[WARN] Skipping cyclic import: %s (import stack: %v)\n", file, stack)
					return
				}
			}
			visited[file] = true
			orderedFiles = append(orderedFiles, file)
			content, ok := fileContentMap[file]
			if !ok {
				fmt.Printf("[WARN] Proto file not found in DB: %s\n", file)
				return
			}
			for _, line := range strings.Split(content, "\n") {
				trimmed := strings.TrimSpace(line)
				if strings.HasPrefix(trimmed, "import ") {
					// Extract import path
					parts := strings.Split(trimmed, "\"")
					if len(parts) >= 2 {
						importPath := parts[1]
						if _, ok := fileContentMap[importPath]; ok {
							dfs(importPath, append(stack, file))
						}
					}
				}
			}
		}
		// Start DFS from all entry files
		for _, entry := range entryFiles {
			dfs(entry, nil)
		}
		// Remove duplicates while preserving order
		uniqueFiles := make([]string, 0, len(orderedFiles))
		seen := make(map[string]struct{})
		for _, f := range orderedFiles {
			if _, ok := seen[f]; !ok {
				uniqueFiles = append(uniqueFiles, f)
				seen[f] = struct{}{}
			}
		}
		entryFiles = uniqueFiles

		parser := protoparse.Parser{
			Accessor: func(filename string) (io.ReadCloser, error) {
				if content, ok := fileContentMap[filename]; ok {
					return io.NopCloser(strings.NewReader(content)), nil
				}
				return nil, fmt.Errorf("proto file not found: %s", filename)
			},
		}

		fds, err := parser.ParseFiles(entryFiles...)
		if err != nil {
			return "", fmt.Errorf("failed to parse proto files: %w", err)
		}

		// Find the service and method descriptors
		var svcDesc *desc.ServiceDescriptor
		var mDesc *desc.MethodDescriptor
		for _, fd := range fds {
			for _, svc := range fd.GetServices() {
				if svc.GetFullyQualifiedName() == serviceName {
					svcDesc = svc
					break
				}
			}
		}
		if svcDesc == nil {
			return "", fmt.Errorf("service not found in parsed protos: %s", serviceName)
		}
		for _, m := range svcDesc.GetMethods() {
			if m.GetName() == methodName {
				mDesc = m
				break
			}
		}
		if mDesc == nil {
			return "", fmt.Errorf("method not found in parsed protos: %s", methodName)
		}
		fmt.Printf("[DEBUG] Found method descriptor: %s\n", mDesc.GetName())

		// Set up headers
		md := metadata.New(nil)
		if headersJSON != "" {
			var headers map[string]string
			if err := json.Unmarshal([]byte(headersJSON), &headers); err == nil {
				for k, v := range headers {
					md.Append(k, v)
				}
			}
		}
		ctx = metadata.NewOutgoingContext(ctx, md)

		// Print the outgoing gRPC call details for debugging
		fmt.Printf("[DEBUG] Intended gRPC method: /%s/%s\n", serviceName, methodName)
		fmt.Printf("[DEBUG] Request JSON: %s\n", requestJSON)
		fmt.Printf("[DEBUG] Headers: %v\n", md)

		// Build and send the dynamic message
		conn, err := a.profileManager.GetConnection(profileID)
		if err != nil {
			return "", fmt.Errorf("no active connection for profile %s: %w", profileID, err)
		}

		// Unary (add debug for request message)
		inputType := mDesc.GetInputType()
		reqMsg := dynamic.NewMessage(inputType)
		if err := reqMsg.UnmarshalJSON([]byte(requestJSON)); err != nil {
			fmt.Printf("[DEBUG] Error building request message from JSON: %v\n", err)
			return "", fmt.Errorf("failed to unmarshal request: %w", err)
		}
		if reqMsg == nil {
			fmt.Printf("[DEBUG] Request message is nil after JSON conversion!\n")
			return "", fmt.Errorf("request message is nil after JSON conversion")
		}
		fmt.Printf("[DEBUG] Built request message: %v\n", reqMsg)

		if mDesc.IsClientStreaming() && !mDesc.IsServerStreaming() {
			// Client streaming (single response)
			var arr []json.RawMessage
			if err := json.Unmarshal([]byte(requestJSON), &arr); err != nil {
				return "", fmt.Errorf("expected JSON array for client streaming: %w", err)
			}
			streamDesc := &grpc.StreamDesc{
				ClientStreams: true,
				ServerStreams: false,
			}
			methodFullName := fmt.Sprintf("/%s/%s", serviceName, methodName)
			stream, err := conn.NewStream(ctx, streamDesc, methodFullName)
			if err != nil {
				return "", fmt.Errorf("failed to open client stream: %w", err)
			}
			s := grpc.ClientStream(stream)
			for _, msgBytes := range arr {
				msg := dynamic.NewMessage(inputType)
				if err := msg.UnmarshalJSON(msgBytes); err != nil {
					return "", fmt.Errorf("failed to unmarshal stream message: %w", err)
				}
				if err := s.SendMsg(msg); err != nil {
					return "", fmt.Errorf("failed to send stream message: %w", err)
				}
			}
			if err := s.CloseSend(); err != nil {
				return "", fmt.Errorf("failed to close stream: %w", err)
			}
			outType := mDesc.GetOutputType()
			respMsg := dynamic.NewMessage(outType)
			if err := s.RecvMsg(respMsg); err != nil {
				return "", fmt.Errorf("failed to receive response: %w", err)
			}
			respJSON, err := respMsg.MarshalJSON()
			if err != nil {
				return "", fmt.Errorf("failed to marshal response: %w", err)
			}
			return string(respJSON), nil
		} else if !mDesc.IsClientStreaming() && mDesc.IsServerStreaming() {
			// Server streaming (single request, multiple responses)
			inputType := mDesc.GetInputType()
			reqMsg := dynamic.NewMessage(inputType)
			if err := reqMsg.UnmarshalJSON([]byte(requestJSON)); err != nil {
				return "", fmt.Errorf("failed to unmarshal request: %w", err)
			}
			streamDesc := &grpc.StreamDesc{
				ClientStreams: false,
				ServerStreams: true,
			}
			methodFullName := fmt.Sprintf("/%s/%s", serviceName, methodName)
			stream, err := conn.NewStream(ctx, streamDesc, methodFullName)
			if err != nil {
				return "", fmt.Errorf("failed to open server stream: %w", err)
			}
			s := grpc.ClientStream(stream)
			if err := s.SendMsg(reqMsg); err != nil {
				return "", fmt.Errorf("failed to send request: %w", err)
			}
			if err := s.CloseSend(); err != nil {
				return "", fmt.Errorf("failed to close send: %w", err)
			}
			outType := mDesc.GetOutputType()
			var responses []json.RawMessage
			for {
				respMsg := dynamic.NewMessage(outType)
				err := s.RecvMsg(respMsg)
				if err != nil {
					if err.Error() == "EOF" {
						break
					}
					return "", fmt.Errorf("failed to receive response: %w", err)
				}
				respJSON, err := respMsg.MarshalJSON()
				if err != nil {
					return "", fmt.Errorf("failed to marshal response: %w", err)
				}
				responses = append(responses, respJSON)
			}
			finalJSON, err := json.Marshal(responses)
			if err != nil {
				return "", fmt.Errorf("failed to marshal responses array: %w", err)
			}
			return string(finalJSON), nil
		} else if mDesc.IsClientStreaming() && mDesc.IsServerStreaming() {
			// Bidirectional streaming (multiple requests, multiple responses)
			var arr []json.RawMessage
			if err := json.Unmarshal([]byte(requestJSON), &arr); err != nil {
				return "", fmt.Errorf("expected JSON array for bidi streaming: %w", err)
			}
			inputType := mDesc.GetInputType()
			streamDesc := &grpc.StreamDesc{
				ClientStreams: true,
				ServerStreams: true,
			}
			methodFullName := fmt.Sprintf("/%s/%s", serviceName, methodName)
			stream, err := conn.NewStream(ctx, streamDesc, methodFullName)
			if err != nil {
				return "", fmt.Errorf("failed to open bidi stream: %w", err)
			}
			s := grpc.ClientStream(stream)
			// Send all requests
			for _, msgBytes := range arr {
				msg := dynamic.NewMessage(inputType)
				if err := msg.UnmarshalJSON(msgBytes); err != nil {
					return "", fmt.Errorf("failed to unmarshal stream message: %w", err)
				}
				if err := s.SendMsg(msg); err != nil {
					return "", fmt.Errorf("failed to send stream message: %w", err)
				}
			}
			if err := s.CloseSend(); err != nil {
				return "", fmt.Errorf("failed to close stream: %w", err)
			}
			outType := mDesc.GetOutputType()
			var responses []json.RawMessage
			for {
				respMsg := dynamic.NewMessage(outType)
				err := s.RecvMsg(respMsg)
				if err != nil {
					if err.Error() == "EOF" {
						break
					}
					return "", fmt.Errorf("failed to receive response: %w", err)
				}
				respJSON, err := respMsg.MarshalJSON()
				if err != nil {
					return "", fmt.Errorf("failed to marshal response: %w", err)
				}
				responses = append(responses, respJSON)
			}
			finalJSON, err := json.Marshal(responses)
			if err != nil {
				return "", fmt.Errorf("failed to marshal responses array: %w", err)
			}
			return string(finalJSON), nil
		} else {
			// Unary
			inputType := mDesc.GetInputType()
			reqMsg := dynamic.NewMessage(inputType)
			if err := reqMsg.UnmarshalJSON([]byte(requestJSON)); err != nil {
				return "", fmt.Errorf("failed to unmarshal request: %w", err)
			}
			outType := mDesc.GetOutputType()
			respMsg := dynamic.NewMessage(outType)
			methodFullName := fmt.Sprintf("/%s/%s", serviceName, methodName)
			err = conn.Invoke(ctx, methodFullName, reqMsg, respMsg)
			if err != nil {
				return "", fmt.Errorf("gRPC call failed: %w", err)
			}
			respJSON, err := respMsg.MarshalJSON()
			if err != nil {
				return "", fmt.Errorf("failed to marshal response: %w", err)
			}
			return string(respJSON), nil
		}
	}

	// --- REFLECTION LOGIC (existing) ---
	// 1. Get connection
	conn, err := a.profileManager.GetConnection(profileID)
	if err != nil {
		return "", fmt.Errorf("no active connection for profile %s: %w", profileID, err)
	}

	// 2. Set up reflection client
	ctx := context.Background()
	rc := grpcreflect.NewClient(ctx, reflectpb.NewServerReflectionClient(conn))
	defer rc.Reset()

	// Try to load well-known types directly
	wellKnownTypes := []string{
		"google.protobuf.Timestamp",
		"google.protobuf.Empty",
		"google.protobuf.Any",
		"google.protobuf.Struct",
		"google.protobuf.DoubleValue",
		"google.protobuf.Duration",
	}

	for _, typeName := range wellKnownTypes {
		fileDesc, err := rc.FileContainingSymbol(typeName)
		if err != nil {
			fmt.Printf("[WARN] Failed to load well-known type %s: %v\n", typeName, err)
		} else {
			fmt.Printf("[DEBUG] Loaded well-known type %s from file: %s\n", typeName, fileDesc.GetName())
		}
	}

	// Get service descriptor
	svcDesc, err := rc.ResolveService(serviceName)
	if err != nil {
		// Log available services for debugging
		services, listErr := rc.ListServices()
		if listErr != nil {
			fmt.Printf("[DEBUG] Failed to list available services: %v\n", listErr)
		} else {
			fmt.Printf("[DEBUG] Available services: %v\n", services)
		}
		return "", fmt.Errorf("service not found: %w", err)
	}

	// Get method descriptor
	mDesc := svcDesc.FindMethodByName(methodName)
	if mDesc == nil {
		// Log available methods for debugging
		methodNames := make([]string, 0)
		for _, m := range svcDesc.GetMethods() {
			methodNames = append(methodNames, m.GetName())
		}
		fmt.Printf("[DEBUG] Available methods for service %s: %v\n", serviceName, methodNames)
		return "", fmt.Errorf("method not found: %s", methodName)
	}
	fmt.Printf("[DEBUG] Found method descriptor: %s\n", mDesc.GetName())

	// Build the request message from JSON
	inputType := mDesc.GetInputType()
	reqMsg := dynamic.NewMessage(inputType)
	if err := reqMsg.UnmarshalJSON([]byte(requestJSON)); err != nil {
		fmt.Printf("[DEBUG] Error building request message from JSON: %v\n", err)
		return "", fmt.Errorf("failed to unmarshal request: %w", err)
	}
	if reqMsg == nil {
		fmt.Printf("[DEBUG] Request message is nil after JSON conversion!\n")
		return "", fmt.Errorf("request message is nil after JSON conversion")
	}
	fmt.Printf("[DEBUG] Built request message: %v\n", reqMsg)

	// Set up headers
	md := metadata.New(nil)
	if headersJSON != "" {
		var headers map[string]string
		if err := json.Unmarshal([]byte(headersJSON), &headers); err == nil {
			for k, v := range headers {
				md.Append(k, v)
			}
		}
	}
	ctx = metadata.NewOutgoingContext(ctx, md)

	// Print the outgoing gRPC call details for debugging (before reflection)
	fmt.Printf("[DEBUG] Intended gRPC method: /%s/%s\n", serviceName, methodName)
	fmt.Printf("[DEBUG] Request JSON: %s\n", requestJSON)
	fmt.Printf("[DEBUG] Headers: %v\n", md)

	// 4. Handle method type
	// Print the outgoing gRPC call details for debugging
	fmt.Printf("[DEBUG] Invoking gRPC method: %s\n", fmt.Sprintf("/%s/%s", svcDesc.GetFullyQualifiedName(), methodName))
	fmt.Printf("[DEBUG] Request JSON: %s\n", requestJSON)
	fmt.Printf("[DEBUG] Headers: %v\n", md)

	if mDesc.IsClientStreaming() && !mDesc.IsServerStreaming() {
		// Client streaming (single response)
		var arr []json.RawMessage
		if err := json.Unmarshal([]byte(requestJSON), &arr); err != nil {
			return "", fmt.Errorf("expected JSON array for client streaming: %w", err)
		}
		inputType := mDesc.GetInputType()
		streamDesc := &grpc.StreamDesc{
			ClientStreams: true,
			ServerStreams: false,
		}
		methodFullName := fmt.Sprintf("/%s/%s", serviceName, methodName)
		stream, err := conn.NewStream(ctx, streamDesc, methodFullName)
		if err != nil {
			return "", fmt.Errorf("failed to open client stream: %w", err)
		}
		s := grpc.ClientStream(stream)
		for _, msgBytes := range arr {
			msg := dynamic.NewMessage(inputType)
			if err := msg.UnmarshalJSON(msgBytes); err != nil {
				return "", fmt.Errorf("failed to unmarshal stream message: %w", err)
			}
			if err := s.SendMsg(msg); err != nil {
				return "", fmt.Errorf("failed to send stream message: %w", err)
			}
		}
		if err := s.CloseSend(); err != nil {
			return "", fmt.Errorf("failed to close stream: %w", err)
		}
		outType := mDesc.GetOutputType()
		respMsg := dynamic.NewMessage(outType)
		if err := s.RecvMsg(respMsg); err != nil {
			return "", fmt.Errorf("failed to receive response: %w", err)
		}
		respJSON, err := respMsg.MarshalJSON()
		if err != nil {
			return "", fmt.Errorf("failed to marshal response: %w", err)
		}
		return string(respJSON), nil
	} else if !mDesc.IsClientStreaming() && mDesc.IsServerStreaming() {
		// Server streaming (single request, multiple responses)
		inputType := mDesc.GetInputType()
		reqMsg := dynamic.NewMessage(inputType)
		if err := reqMsg.UnmarshalJSON([]byte(requestJSON)); err != nil {
			return "", fmt.Errorf("failed to unmarshal request: %w", err)
		}
		streamDesc := &grpc.StreamDesc{
			ClientStreams: false,
			ServerStreams: true,
		}
		methodFullName := fmt.Sprintf("/%s/%s", serviceName, methodName)
		stream, err := conn.NewStream(ctx, streamDesc, methodFullName)
		if err != nil {
			return "", fmt.Errorf("failed to open server stream: %w", err)
		}
		s := grpc.ClientStream(stream)
		if err := s.SendMsg(reqMsg); err != nil {
			return "", fmt.Errorf("failed to send request: %w", err)
		}
		if err := s.CloseSend(); err != nil {
			return "", fmt.Errorf("failed to close send: %w", err)
		}
		outType := mDesc.GetOutputType()
		var responses []json.RawMessage
		for {
			respMsg := dynamic.NewMessage(outType)
			err := s.RecvMsg(respMsg)
			if err != nil {
				if err.Error() == "EOF" {
					break
				}
				return "", fmt.Errorf("failed to receive response: %w", err)
			}
			respJSON, err := respMsg.MarshalJSON()
			if err != nil {
				return "", fmt.Errorf("failed to marshal response: %w", err)
			}
			responses = append(responses, respJSON)
		}
		finalJSON, err := json.Marshal(responses)
		if err != nil {
			return "", fmt.Errorf("failed to marshal responses array: %w", err)
		}
		return string(finalJSON), nil
	} else if mDesc.IsClientStreaming() && mDesc.IsServerStreaming() {
		// Bidirectional streaming (multiple requests, multiple responses)
		var arr []json.RawMessage
		if err := json.Unmarshal([]byte(requestJSON), &arr); err != nil {
			return "", fmt.Errorf("expected JSON array for bidi streaming: %w", err)
		}
		inputType := mDesc.GetInputType()
		streamDesc := &grpc.StreamDesc{
			ClientStreams: true,
			ServerStreams: true,
		}
		methodFullName := fmt.Sprintf("/%s/%s", serviceName, methodName)
		stream, err := conn.NewStream(ctx, streamDesc, methodFullName)
		if err != nil {
			return "", fmt.Errorf("failed to open bidi stream: %w", err)
		}
		s := grpc.ClientStream(stream)
		// Send all requests
		for _, msgBytes := range arr {
			msg := dynamic.NewMessage(inputType)
			if err := msg.UnmarshalJSON(msgBytes); err != nil {
				return "", fmt.Errorf("failed to unmarshal stream message: %w", err)
			}
			if err := s.SendMsg(msg); err != nil {
				return "", fmt.Errorf("failed to send stream message: %w", err)
			}
		}
		if err := s.CloseSend(); err != nil {
			return "", fmt.Errorf("failed to close send: %w", err)
		}
		outType := mDesc.GetOutputType()
		var responses []json.RawMessage
		for {
			respMsg := dynamic.NewMessage(outType)
			err := s.RecvMsg(respMsg)
			if err != nil {
				if err.Error() == "EOF" {
					break
				}
				return "", fmt.Errorf("failed to receive response: %w", err)
			}
			respJSON, err := respMsg.MarshalJSON()
			if err != nil {
				return "", fmt.Errorf("failed to marshal response: %w", err)
			}
			responses = append(responses, respJSON)
		}
		finalJSON, err := json.Marshal(responses)
		if err != nil {
			return "", fmt.Errorf("failed to marshal responses array: %w", err)
		}
		return string(finalJSON), nil
	} else {
		// Unary
		inputType := mDesc.GetInputType()
		reqMsg := dynamic.NewMessage(inputType)
		if err := reqMsg.UnmarshalJSON([]byte(requestJSON)); err != nil {
			return "", fmt.Errorf("failed to unmarshal request: %w", err)
		}
		outType := mDesc.GetOutputType()
		respMsg := dynamic.NewMessage(outType)
		// Use the full service name from the service descriptor
		methodFullName := fmt.Sprintf("/%s/%s", svcDesc.GetFullyQualifiedName(), methodName)
		err = conn.Invoke(ctx, methodFullName, reqMsg, respMsg)
		if err != nil {
			return "", fmt.Errorf("gRPC call failed: %w", err)
		}
		respJSON, err := respMsg.MarshalJSON()
		if err != nil {
			return "", fmt.Errorf("failed to marshal response: %w", err)
		}
		return string(respJSON), nil
	}
}

// RegisterWellKnownTypesFromDB loads all well-known types from the store and registers them with the protobuf global registry.
func RegisterWellKnownTypesFromDB(ctx context.Context, store services.ServerProfileStore) error {
	wkts, err := store.ListWellKnownTypes(ctx)
	if err != nil {
		return err
	}
	for _, wkt := range wkts {
		fd := &descriptorpb.FileDescriptorProto{}
		// Try to parse as proto text first
		if err := prototext.Unmarshal([]byte(wkt.Content), fd); err != nil {
			// fallback: try binary unmarshal
			if err := goproto.Unmarshal([]byte(wkt.Content), fd); err != nil {
				fmt.Printf("[WARN] Failed to parse well-known type %s: %v\n", wkt.TypeName, err)
				continue
			}
		}
		fileDesc, err := protodesc.NewFile(fd, protoregistry.GlobalFiles)
		if err != nil {
			fmt.Printf("[WARN] Failed to create file descriptor for %s: %v\n", wkt.TypeName, err)
			continue
		}
		if err := protoregistry.GlobalFiles.RegisterFile(fileDesc); err != nil && !strings.Contains(err.Error(), "already registered") {
			fmt.Printf("[WARN] Failed to register file descriptor for %s: %v\n", wkt.TypeName, err)
		}
	}
	return nil
}

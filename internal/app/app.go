package app

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"protodesk/pkg/models"
	"protodesk/pkg/models/proto"
	"protodesk/pkg/services"

	"github.com/google/uuid"
	"github.com/jhump/protoreflect/dynamic"
	"github.com/jhump/protoreflect/grpcreflect"
	"github.com/wailsapp/wails/v2/pkg/runtime"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
	reflectpb "google.golang.org/grpc/reflection/grpc_reflection_v1alpha"
	pbproto "google.golang.org/protobuf/proto"
	descriptorpb "google.golang.org/protobuf/types/descriptorpb"
)

// App struct represents the main application
type App struct {
	ctx            context.Context
	profileManager *services.ServerProfileManager
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

	a.profileManager = services.NewServerProfileManager(store)
	fmt.Println("[Startup] profileManager initialized successfully")
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
	if a.profileManager == nil {
		return nil, fmt.Errorf("profileManager is not initialized")
	}
	return a.profileManager.ListProtoDefinitionsByProfile(profileID)
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
	if a.ctx == nil {
		return fmt.Errorf("context not initialized")
	}

	// Get the absolute path
	absPath, err := filepath.Abs(path)
	if err != nil {
		return fmt.Errorf("failed to get absolute path: %w", err)
	}
	fmt.Printf("[PATH_SCAN] Starting scan at: %s\n", absPath)

	// Create a map to store unique import paths
	importPaths := make(map[string]bool)
	importPaths[absPath] = true // Use the exact path the user selected

	// Create a map to store unique proto files
	protoFilesMap := make(map[string]bool)

	// First pass: collect all directories that contain .proto files
	err = filepath.Walk(absPath, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		fmt.Printf("[PATH_SCAN] First pass - Path: %s (isDir: %v)\n", path, info.IsDir())

		// Skip anything in node_modules
		if strings.Contains(path, "node_modules") {
			fmt.Printf("[PATH_SCAN] !!! Found node_modules in path: %s, skipping entire directory !!!\n", path)
			return filepath.SkipDir
		}

		if info.IsDir() {
			// Check if this directory contains any .proto files
			entries, err := os.ReadDir(path)
			if err != nil {
				return err
			}
			for _, entry := range entries {
				if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".proto") {
					importPaths[path] = true
					fmt.Printf("[PATH_SCAN] Added import path: %s\n", path)
					break
				}
			}
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("failed to scan directory: %w", err)
	}

	// Convert map to sorted slice of paths (most specific first)
	var paths []string
	for p := range importPaths {
		paths = append(paths, p)
	}
	sort.Slice(paths, func(i, j int) bool {
		// Sort by path length in descending order (most specific first)
		return len(paths[i]) > len(paths[j])
	})

	fmt.Printf("[PATH_SCAN] === Collected import paths before second pass ===\n")
	for _, p := range paths {
		fmt.Printf("[PATH_SCAN] Import path: %s\n", p)
	}
	fmt.Printf("[PATH_SCAN] === End of import paths ===\n")

	// Second pass: collect all .proto files
	err = filepath.Walk(absPath, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		fmt.Printf("[PATH_SCAN] Second pass - Path: %s (isDir: %v)\n", path, info.IsDir())

		// Skip anything in node_modules
		if strings.Contains(path, "node_modules") {
			fmt.Printf("[PATH_SCAN] !!! Second pass found node_modules in path: %s, skipping entire directory !!!\n", path)
			return filepath.SkipDir
		}

		if !info.IsDir() && strings.HasSuffix(info.Name(), ".proto") {
			protoFilesMap[path] = true
			fmt.Printf("[PATH_SCAN] Found proto file: %s\n", path)
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("failed to collect proto files: %w", err)
	}

	// Convert map to slice
	var protoFiles []string
	for p := range protoFilesMap {
		protoFiles = append(protoFiles, p)
	}

	fmt.Printf("[PATH_SCAN] Total proto files to parse: %d\n", len(protoFiles))
	fmt.Printf("[PATH_SCAN] Total import paths: %d\n", len(paths))

	// Parse each proto file
	for _, protoFile := range protoFiles {
		fmt.Printf("[PATH_SCAN] Parsing proto file: %s\n", protoFile)

		// Build protoc command with all import paths
		args := []string{
			"--descriptor_set_out=" + protoFile + ".pb",
			"--include_imports",
		}

		// Add import paths in order (most specific first)
		for _, p := range paths {
			args = append(args, "--proto_path="+p)
		}

		// Add the proto file
		args = append(args, protoFile)

		fmt.Printf("[PATH_SCAN] Running protoc with args: %v\n", args)

		// Run protoc
		cmd := exec.Command("protoc", args...)
		output, err := cmd.CombinedOutput()
		if err != nil {
			// Clean up the descriptor file if it was created
			os.Remove(protoFile + ".pb")
			fmt.Printf("[PATH_SCAN] ERROR: protoc failed for %s: %v\nOutput: %s\n", protoFile, err, string(output))
			continue // Skip this file but continue with others
		}

		// Always log protoc output for debugging
		fmt.Printf("[PATH_SCAN] protoc output for %s: %s\n", protoFile, string(output))

		// Check if the descriptor file was created
		if _, err := os.Stat(protoFile + ".pb"); os.IsNotExist(err) {
			fmt.Printf("[PATH_SCAN] ERROR: Descriptor file was not created for %s\n", protoFile)
			continue
		}

		// Read the descriptor file
		descriptorData, err := os.ReadFile(protoFile + ".pb")
		if err != nil {
			os.Remove(protoFile + ".pb")
			fmt.Printf("[PATH_SCAN] ERROR: Failed to read descriptor file for %s: %v\n", protoFile, err)
			continue // Skip this file but continue with others
		}

		// Clean up the descriptor file
		os.Remove(protoFile + ".pb")

		// Parse the descriptor file
		var descriptorSet descriptorpb.FileDescriptorSet
		if err := pbproto.Unmarshal(descriptorData, &descriptorSet); err != nil {
			fmt.Printf("[PATH_SCAN] ERROR: Failed to parse descriptor file for %s: %v\n", protoFile, err)
			continue // Skip this file but continue with others
		}

		fmt.Printf("[PATH_SCAN] Successfully parsed descriptor set for %s\n", protoFile)
		fmt.Printf("[PATH_SCAN] Number of files in descriptor set: %d\n", len(descriptorSet.GetFile()))

		// Read the original proto file content
		content, err := os.ReadFile(protoFile)
		if err != nil {
			fmt.Printf("[PATH_SCAN] ERROR: Failed to read proto file %s: %v\n", protoFile, err)
			continue // Skip this file but continue with others
		}

		// Process the descriptor set
		for _, file := range descriptorSet.GetFile() {
			// Convert the file name to a relative path that matches our format
			descriptorFileName := file.GetName()
			fmt.Printf("[PATH_SCAN] Checking descriptor file: %s\n", descriptorFileName)

			// Skip if this isn't the main file we're processing
			// The descriptor set includes all imported files, but we only want to process the main file
			if !strings.HasSuffix(descriptorFileName, filepath.Base(protoFile)) {
				fmt.Printf("[PATH_SCAN] Skipping imported file: %s\n", descriptorFileName)
				continue
			}

			fmt.Printf("[PATH_SCAN] Processing file: %s\n", protoFile)
			fmt.Printf("[PATH_SCAN] Number of services in file: %d\n", len(file.GetService()))

			// Store the proto definition in the database
			def := &proto.ProtoDefinition{
				ID:              uuid.New().String(),
				FilePath:        protoFile, // Use absolute path for scanned files
				Content:         string(content),
				Imports:         file.GetDependency(),
				Services:        make([]proto.Service, 0),
				CreatedAt:       time.Now(),
				UpdatedAt:       time.Now(),
				ServerProfileID: serverProfileId,
				ProtoPathID:     protoPathId,
			}

			// Extract service names and methods
			for _, service := range file.GetService() {
				fmt.Printf("[PATH_SCAN] Found service: %s\n", service.GetName())
				serviceDef := proto.Service{
					Name:        service.GetName(),
					Methods:     make([]proto.Method, 0),
					Description: fmt.Sprintf("%v", service.GetOptions().GetDeprecated()),
				}

				// Extract methods
				for _, method := range service.GetMethod() {
					fmt.Printf("[PATH_SCAN] Found method: %s in service %s\n", method.GetName(), service.GetName())
					methodDef := proto.Method{
						Name:        method.GetName(),
						Description: fmt.Sprintf("%v", method.GetOptions().GetDeprecated()),
						InputType: proto.MessageType{
							Name: method.GetInputType(),
						},
						OutputType: proto.MessageType{
							Name: method.GetOutputType(),
						},
					}
					serviceDef.Methods = append(serviceDef.Methods, methodDef)
				}

				def.Services = append(def.Services, serviceDef)
			}

			fmt.Printf("[PATH_SCAN] Created proto definition with %d services\n", len(def.Services))

			// Check if a proto definition with the same path already exists
			existingDefs, err := a.profileManager.GetStore().ListProtoDefinitionsByProfile(a.ctx, serverProfileId)
			if err != nil {
				fmt.Printf("[PATH_SCAN] ERROR: Failed to list proto definitions: %v\n", err)
				continue // Skip this file but continue with others
			}

			var existingDef *proto.ProtoDefinition
			for _, d := range existingDefs {
				if d.FilePath == protoFile { // Compare absolute paths
					existingDef = d
					break
				}
			}

			if existingDef != nil {
				// Update existing definition
				def.ID = existingDef.ID
				def.CreatedAt = existingDef.CreatedAt
				err = a.profileManager.GetStore().UpdateProtoDefinition(a.ctx, def)
				if err != nil {
					fmt.Printf("[PATH_SCAN] ERROR: Failed to update proto definition: %v\n", err)
				} else {
					fmt.Printf("[PATH_SCAN] Updated existing proto definition: %s\n", protoFile)
				}
			} else {
				// Create new definition
				err = a.profileManager.GetStore().CreateProtoDefinition(a.ctx, def)
				if err != nil {
					fmt.Printf("[PATH_SCAN] ERROR: Failed to create proto definition: %v\n", err)
				} else {
					fmt.Printf("[PATH_SCAN] Created new proto definition: %s\n", protoFile)
				}
			}
		}
	}

	return nil
}

// CreateProtoPath creates a proto path record in the database and links it to a server profile
func (a *App) CreateProtoPath(id, serverProfileId, path string) error {
	if a.profileManager == nil {
		return fmt.Errorf("profile manager not initialized; startup may not have run successfully")
	}
	fmt.Printf("[DEBUG] Creating proto path with ID: %s, ServerProfileID: %s, Path: %s\n", id, serverProfileId, path)
	protoPath := &services.ProtoPath{
		ID:              id,
		ServerProfileID: serverProfileId,
		Path:            path,
	}
	err := a.profileManager.GetStore().CreateProtoPath(context.Background(), protoPath)
	if err != nil {
		fmt.Printf("[ERROR] Failed to create proto path: %v\n", err)
		return err
	}
	fmt.Printf("[DEBUG] Successfully created proto path\n")
	return nil
}

// ListProtoPathsByServer lists proto paths for a given server profile
func (a *App) ListProtoPathsByServer(serverID string) ([]*services.ProtoPath, error) {
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
	// 1. Get connection
	conn, err := a.profileManager.GetConnection(profileID)
	if err != nil {
		return "", fmt.Errorf("no active connection for profile %s: %w", profileID, err)
	}

	// 2. Set up reflection client
	ctx := context.Background()
	rc := grpcreflect.NewClient(ctx, reflectpb.NewServerReflectionClient(conn))
	defer rc.Reset()

	svcDesc, err := rc.ResolveService(serviceName)
	if err != nil {
		return "", fmt.Errorf("service not found: %w", err)
	}
	mDesc := svcDesc.FindMethodByName(methodName)
	if mDesc == nil {
		return "", fmt.Errorf("method not found: %s", methodName)
	}

	// 3. Set up headers
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

	// 4. Handle method type
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
	} else if !mDesc.IsClientStreaming() && !mDesc.IsServerStreaming() {
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
	} else {
		return "", fmt.Errorf("unknown gRPC method type")
	}
}

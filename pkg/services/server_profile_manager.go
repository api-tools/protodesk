package services

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"protodesk/pkg/models/proto"

	"github.com/google/uuid"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
	pbproto "google.golang.org/protobuf/proto"
	descriptorpb "google.golang.org/protobuf/types/descriptorpb"
)

// ServerProfileManager handles server profile operations and maintains active connections
type ServerProfileManager struct {
	store         ServerProfileStore
	grpcClient    GRPCClientManager
	activeClients map[string]*grpc.ClientConn
	mu            sync.RWMutex
}

// NewServerProfileManager creates a new server profile manager
func NewServerProfileManager(store ServerProfileStore) *ServerProfileManager {
	return &ServerProfileManager{
		store:         store,
		grpcClient:    NewGRPCClientManager(),
		activeClients: make(map[string]*grpc.ClientConn),
	}
}

// GetStore returns the underlying ServerProfileStore
func (m *ServerProfileManager) GetStore() ServerProfileStore {
	return m.store
}

// Connect establishes a gRPC connection to the specified server profile
func (m *ServerProfileManager) Connect(ctx context.Context, profileID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	profile, err := m.store.Get(ctx, profileID)
	if err != nil {
		return fmt.Errorf("failed to get profile: %w", err)
	}

	// Build target address
	target := fmt.Sprintf("%s:%d", profile.Host, profile.Port)

	// Check if connection already exists
	if _, exists := m.activeClients[profileID]; exists {
		return nil // Already connected
	}

	// Establish new connection
	certPath := ""
	if profile.CertificatePath != nil {
		certPath = *profile.CertificatePath
	}

	// Automatically enable TLS for port 443
	useTLS := profile.TLSEnabled || profile.Port == 443

	// Add headers to the context
	ctxWithHeaders := ctx
	if len(profile.Headers) > 0 {
		md := metadata.New(nil)
		for _, header := range profile.Headers {
			md.Append(header.Key, header.Value)
		}
		ctxWithHeaders = metadata.NewOutgoingContext(ctx, md)
	}

	if err := m.grpcClient.Connect(ctxWithHeaders, target, useTLS, certPath); err != nil {
		return fmt.Errorf("failed to connect: %w", err)
	}

	conn, err := m.grpcClient.GetConnection(target)
	if err != nil {
		return fmt.Errorf("failed to get connection: %w", err)
	}

	// If reflection is enabled, try to get services and methods
	if profile.UseReflection {
		services, err := m.grpcClient.ListServicesAndMethods(conn)
		if err != nil {
			// Log the error but don't fail the connection
			fmt.Printf("[WARN] Failed to list services via reflection: %v\n", err)
		} else {
			// Store the services in the database
			for serviceName, methods := range services {
				// Create a proto definition for each service
				def := &proto.ProtoDefinition{
					ID:              uuid.New().String(),
					FilePath:        fmt.Sprintf("reflection/%s.proto", serviceName),
					Content:         fmt.Sprintf("service %s {\n  // Methods: %v\n}", serviceName, methods),
					Services:        []proto.Service{{Name: serviceName}},
					CreatedAt:       time.Now(),
					UpdatedAt:       time.Now(),
					ServerProfileID: profileID,
				}

				// Check if a proto definition with the same path already exists
				existingDefs, err := m.store.ListProtoDefinitionsByProfile(ctx, profileID)
				if err != nil {
					fmt.Printf("[WARN] Failed to list proto definitions: %v\n", err)
					continue
				}

				var existingDef *proto.ProtoDefinition
				for _, d := range existingDefs {
					if d.FilePath == def.FilePath {
						existingDef = d
						break
					}
				}

				if existingDef != nil {
					// Update existing definition
					def.ID = existingDef.ID
					def.CreatedAt = existingDef.CreatedAt
					err = m.store.UpdateProtoDefinition(ctx, def)
					if err != nil {
						fmt.Printf("[WARN] Failed to update proto definition: %v\n", err)
					}
				} else {
					// Create new definition
					err = m.store.CreateProtoDefinition(ctx, def)
					if err != nil {
						fmt.Printf("[WARN] Failed to create proto definition: %v\n", err)
					}
				}
			}
		}
	}

	m.activeClients[profileID] = conn
	return nil
}

// Disconnect closes the gRPC connection for the specified profile
func (m *ServerProfileManager) Disconnect(ctx context.Context, profileID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	profile, err := m.store.Get(ctx, profileID)
	if err != nil {
		return fmt.Errorf("failed to get profile: %w", err)
	}

	target := fmt.Sprintf("%s:%d", profile.Host, profile.Port)
	if err := m.grpcClient.Disconnect(target); err != nil {
		return fmt.Errorf("failed to disconnect: %w", err)
	}

	delete(m.activeClients, profileID)
	return nil
}

// GetConnection returns an active gRPC connection for the specified profile
func (m *ServerProfileManager) GetConnection(profileID string) (*grpc.ClientConn, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	conn, exists := m.activeClients[profileID]
	if !exists {
		return nil, fmt.Errorf("no active connection for profile %s", profileID)
	}
	return conn, nil
}

// IsConnected checks if a profile has an active connection
func (m *ServerProfileManager) IsConnected(profileID string) bool {
	m.mu.RLock()
	defer m.mu.RUnlock()

	_, exists := m.activeClients[profileID]
	return exists
}

// DisconnectAll closes all active connections
func (m *ServerProfileManager) DisconnectAll() {
	m.mu.Lock()
	defer m.mu.Unlock()

	for id := range m.activeClients {
		if profile, err := m.store.Get(context.Background(), id); err == nil {
			target := fmt.Sprintf("%s:%d", profile.Host, profile.Port)
			_ = m.grpcClient.Disconnect(target)
		}
	}
	m.activeClients = make(map[string]*grpc.ClientConn)
}

// SetGRPCClient sets the gRPC client manager (useful for testing)
func (m *ServerProfileManager) SetGRPCClient(client GRPCClientManager) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.grpcClient = client
}

// GetGRPCClient returns the GRPCClientManager
func (m *ServerProfileManager) GetGRPCClient() GRPCClientManager {
	return m.grpcClient
}

// ListProtoDefinitionsByProfile lists all proto definitions for a given profile
func (m *ServerProfileManager) ListProtoDefinitionsByProfile(profileID string) ([]*proto.ProtoDefinition, error) {
	fmt.Printf("[DEBUG] ListProtoDefinitionsByProfile called for profile: %s\n", profileID)

	// Get the profile
	profile, err := m.store.Get(context.Background(), profileID)
	if err != nil {
		fmt.Printf("[ERROR] Failed to get profile: %v\n", err)
		return nil, err
	}

	// Get all proto paths for this profile
	protoPaths, err := m.store.ListProtoPathsByServer(context.Background(), profileID)
	if err != nil {
		fmt.Printf("[ERROR] Failed to list proto paths: %v\n", err)
		return nil, err
	}

	// If no proto paths are configured, return existing proto definitions
	if len(protoPaths) == 0 {
		fmt.Printf("[DEBUG] No proto paths configured, returning existing proto definitions\n")
		return m.store.ListProtoDefinitionsByProfile(context.Background(), profileID)
	}

	// If reflection is enabled, use reflection
	if profile.UseReflection {
		fmt.Printf("[DEBUG] Using reflection to list services\n")
		// Build target address
		target := fmt.Sprintf("%s:%d", profile.Host, profile.Port)
		fmt.Printf("[DEBUG] Getting connection for target: %s\n", target)
		conn, err := m.grpcClient.GetConnection(target)
		if err != nil {
			fmt.Printf("[ERROR] Failed to get connection: %v\n", err)
			return nil, err
		}
		fmt.Printf("[DEBUG] Got connection %p\n", conn)

		// List services and methods
		fmt.Printf("[DEBUG] Calling ListServicesAndMethods with connection %p\n", conn)
		services, err := m.grpcClient.ListServicesAndMethods(conn)
		if err != nil {
			fmt.Printf("[ERROR] Failed to list services: %v\n", err)
			return nil, err
		}

		// Convert services map to ProtoDefinition objects
		var definitions []*proto.ProtoDefinition
		for serviceName, methods := range services {
			// Create a proto definition for each service
			def := &proto.ProtoDefinition{
				ID:              uuid.New().String(),
				FilePath:        fmt.Sprintf("reflection/%s.proto", serviceName),
				Content:         fmt.Sprintf("service %s {\n  // Methods: %v\n}", serviceName, methods),
				Services:        []proto.Service{{Name: serviceName}},
				CreatedAt:       time.Now(),
				UpdatedAt:       time.Now(),
				ServerProfileID: profileID,
			}

			// Check if a proto definition with the same path already exists
			existingDefs, err := m.store.ListProtoDefinitionsByProfile(context.Background(), profileID)
			if err != nil {
				fmt.Printf("[WARN] Failed to list proto definitions: %v\n", err)
				continue
			}

			var existingDef *proto.ProtoDefinition
			for _, d := range existingDefs {
				if d.FilePath == def.FilePath {
					existingDef = d
					break
				}
			}

			if existingDef != nil {
				// Update existing definition
				def.ID = existingDef.ID
				def.CreatedAt = existingDef.CreatedAt
				err = m.store.UpdateProtoDefinition(context.Background(), def)
				if err != nil {
					fmt.Printf("[WARN] Failed to update proto definition: %v\n", err)
				}
			} else {
				// Create new definition
				err = m.store.CreateProtoDefinition(context.Background(), def)
				if err != nil {
					fmt.Printf("[WARN] Failed to create proto definition: %v\n", err)
				}
			}

			definitions = append(definitions, def)
		}

		return definitions, nil
	}

	// If reflection is not enabled, use proto files
	fmt.Printf("[DEBUG] Using proto files to list services\n")

	// Process each proto path
	for _, protoPath := range protoPaths {
		// Scan and parse the proto path
		err = m.scanAndParseProtoPath(profileID, protoPath.ID, protoPath.Path)
		if err != nil {
			fmt.Printf("[WARN] Failed to scan proto path %s: %v\n", protoPath.Path, err)
			continue
		}
	}

	// Return the most up-to-date definitions
	return m.store.ListProtoDefinitionsByProfile(context.Background(), profileID)
}

// scanAndParseProtoPath scans a proto path, parses all .proto files, and stores results in the DB
func (m *ServerProfileManager) scanAndParseProtoPath(serverProfileId string, protoPathId string, path string) error {
	fmt.Printf("[DEBUG] Scanning proto path: %s\n", path)

	// Get the absolute path
	absPath, err := filepath.Abs(path)
	if err != nil {
		return fmt.Errorf("failed to get absolute path: %w", err)
	}

	// Create a map to store unique import paths
	importPaths := make(map[string]bool)
	importPaths[absPath] = true

	// First pass: collect all directories that contain .proto files
	err = filepath.Walk(absPath, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		// Skip anything in node_modules
		if strings.Contains(path, "node_modules") {
			fmt.Printf("[DEBUG] Skipping node_modules path: %s\n", path)
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
					fmt.Printf("[DEBUG] Added import path: %s\n", path)
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

	// Second pass: collect all .proto files
	var protoFiles []string
	err = filepath.Walk(absPath, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		// Skip anything in node_modules
		if strings.Contains(path, "node_modules") {
			fmt.Printf("[DEBUG] Skipping node_modules path: %s\n", path)
			return filepath.SkipDir
		}

		if !info.IsDir() && strings.HasSuffix(info.Name(), ".proto") {
			protoFiles = append(protoFiles, path)
			fmt.Printf("[DEBUG] Found proto file: %s\n", path)
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("failed to collect proto files: %w", err)
	}

	fmt.Printf("[DEBUG] Total proto files to parse: %d\n", len(protoFiles))
	fmt.Printf("[DEBUG] Total import paths: %d\n", len(paths))

	// Parse each proto file
	for _, protoFile := range protoFiles {
		fmt.Printf("[DEBUG] Parsing proto file: %s\n", protoFile)

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

		// Run protoc
		cmd := exec.Command("protoc", args...)
		output, err := cmd.CombinedOutput()
		if err != nil {
			// Clean up the descriptor file if it was created
			os.Remove(protoFile + ".pb")
			fmt.Printf("[ERROR] protoc failed for %s: %v\nOutput: %s\n", protoFile, err, string(output))
			continue // Skip this file but continue with others
		}

		// Always log protoc output for debugging
		fmt.Printf("[DEBUG] protoc output for %s: %s\n", protoFile, string(output))

		// Check if the descriptor file was created
		if _, err := os.Stat(protoFile + ".pb"); os.IsNotExist(err) {
			fmt.Printf("[ERROR] Descriptor file was not created for %s\n", protoFile)
			continue
		}

		// Read the descriptor file
		descriptorData, err := os.ReadFile(protoFile + ".pb")
		if err != nil {
			os.Remove(protoFile + ".pb")
			fmt.Printf("[ERROR] Failed to read descriptor file for %s: %v\n", protoFile, err)
			continue // Skip this file but continue with others
		}

		// Clean up the descriptor file
		os.Remove(protoFile + ".pb")

		// Parse the descriptor file
		var descriptorSet descriptorpb.FileDescriptorSet
		if err := pbproto.Unmarshal(descriptorData, &descriptorSet); err != nil {
			fmt.Printf("[ERROR] Failed to parse descriptor file for %s: %v\n", protoFile, err)
			continue // Skip this file but continue with others
		}

		fmt.Printf("[DEBUG] Successfully parsed descriptor set for %s\n", protoFile)
		fmt.Printf("[DEBUG] Number of files in descriptor set: %d\n", len(descriptorSet.GetFile()))

		// Read the original proto file content
		content, err := os.ReadFile(protoFile)
		if err != nil {
			fmt.Printf("[ERROR] Failed to read proto file %s: %v\n", protoFile, err)
			continue // Skip this file but continue with others
		}

		// Process the descriptor set
		for _, file := range descriptorSet.GetFile() {
			// Convert the file name to a relative path that matches our format
			descriptorFileName := file.GetName()
			fmt.Printf("[DEBUG] Checking descriptor file: %s\n", descriptorFileName)

			// Skip if this isn't the main file we're processing
			// The descriptor set includes all imported files, but we only want to process the main file
			if !strings.HasSuffix(descriptorFileName, filepath.Base(protoFile)) {
				fmt.Printf("[DEBUG] Skipping imported file: %s\n", descriptorFileName)
				continue
			}

			fmt.Printf("[DEBUG] Processing file: %s\n", protoFile)
			fmt.Printf("[DEBUG] Number of services in file: %d\n", len(file.GetService()))

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
				fmt.Printf("[DEBUG] Found service: %s\n", service.GetName())
				serviceDef := proto.Service{
					Name:        service.GetName(),
					Methods:     make([]proto.Method, 0),
					Description: fmt.Sprintf("%v", service.GetOptions().GetDeprecated()),
				}

				// Extract methods
				for _, method := range service.GetMethod() {
					fmt.Printf("[DEBUG] Found method: %s in service %s\n", method.GetName(), service.GetName())
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

			fmt.Printf("[DEBUG] Created proto definition with %d services\n", len(def.Services))

			// Check if a proto definition with the same path already exists
			existingDefs, err := m.store.ListProtoDefinitionsByProfile(context.Background(), serverProfileId)
			if err != nil {
				fmt.Printf("[ERROR] Failed to list proto definitions: %v\n", err)
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
				err = m.store.UpdateProtoDefinition(context.Background(), def)
				if err != nil {
					fmt.Printf("[ERROR] Failed to update proto definition: %v\n", err)
				} else {
					fmt.Printf("[DEBUG] Updated existing proto definition: %s\n", protoFile)
				}
			} else {
				// Create new definition
				err = m.store.CreateProtoDefinition(context.Background(), def)
				if err != nil {
					fmt.Printf("[ERROR] Failed to create proto definition: %v\n", err)
				} else {
					fmt.Printf("[DEBUG] Created new proto definition: %s\n", protoFile)
				}
			}
		}
	}

	return nil
}

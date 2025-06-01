package services

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jhump/protoreflect/grpcreflect"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
	reflectionpb "google.golang.org/grpc/reflection/grpc_reflection_v1alpha"

	"protodesk/pkg/models"
	"protodesk/pkg/models/proto"

	"crypto/sha256"
	"encoding/hex"
)

// ServerProfileManager handles server profile operations and maintains active connections
type ServerProfileManager struct {
	store         ServerProfileStore
	grpcClient    GRPCClientManager
	activeClients map[string]*grpc.ClientConn
	mu            sync.RWMutex
	protoParser   *ProtoParser
}

// NewServerProfileManager creates a new server profile manager
func NewServerProfileManager(store ServerProfileStore) *ServerProfileManager {
	return &ServerProfileManager{
		store:         store,
		grpcClient:    NewGRPCClientManager(),
		activeClients: make(map[string]*grpc.ClientConn),
		protoParser:   NewProtoParser(store),
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
			// Get the reflection client
			rc := grpcreflect.NewClient(ctx, reflectionpb.NewServerReflectionClient(conn))
			defer rc.Reset()

			// Store the services in the database
			for serviceName, methods := range services {
				// Get the service descriptor
				svcDesc, err := rc.ResolveService(serviceName)
				if err != nil {
					fmt.Printf("[WARN] Failed to resolve service %s: %v\n", serviceName, err)
					continue
				}

				// Create a proto definition for each service
				def := &proto.ProtoDefinition{
					ID:              uuid.New().String(),
					FilePath:        fmt.Sprintf("reflection/%s.proto", serviceName),
					Content:         fmt.Sprintf("service %s {\n  // Methods: %v\n}", serviceName, methods),
					Services:        []proto.Service{{Name: serviceName}},
					Messages:        make([]proto.MessageType, 0),
					Imports:         []string{"google/protobuf/timestamp.proto"},
					CreatedAt:       time.Now(),
					UpdatedAt:       time.Now(),
					ServerProfileID: profileID,
				}

				// Extract message types from methods
				for _, method := range methods {
					// Get method descriptor
					mDesc := svcDesc.FindMethodByName(method)
					if mDesc == nil {
						continue
					}

					// Get input type
					inputType := mDesc.GetInputType()
					if inputType != nil {
						msg := proto.MessageType{
							Name:   inputType.GetFullyQualifiedName(),
							Fields: make([]proto.MessageField, 0),
						}
						// Only add if it's not already in the list
						found := false
						for _, existing := range def.Messages {
							if existing.Name == msg.Name {
								found = true
								break
							}
						}
						if !found {
							def.Messages = append(def.Messages, msg)
						}
					}

					// Get output type
					outputType := mDesc.GetOutputType()
					if outputType != nil {
						msg := proto.MessageType{
							Name:   outputType.GetFullyQualifiedName(),
							Fields: make([]proto.MessageField, 0),
						}
						// Only add if it's not already in the list
						found := false
						for _, existing := range def.Messages {
							if existing.Name == msg.Name {
								found = true
								break
							}
						}
						if !found {
							def.Messages = append(def.Messages, msg)
						}
					}
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
func (m *ServerProfileManager) ListProtoDefinitionsByProfile(ctx context.Context, profileID string) ([]*proto.ProtoDefinition, error) {
	fmt.Printf("[DEBUG] Method: ListProtoDefinitionsByProfile - Starting for profile: %s\n", profileID)

	// First check if we have any definitions
	defs, err := m.store.ListProtoDefinitionsByProfile(ctx, profileID)
	if err != nil {
		fmt.Printf("[DEBUG] Method: ListProtoDefinitionsByProfile - Failed to list proto definitions: %v\n", err)
		return nil, fmt.Errorf("failed to list proto definitions: %w", err)
	}

	// If we have definitions, return them
	if len(defs) > 0 {
		fmt.Printf("[DEBUG] Method: ListProtoDefinitionsByProfile - Found %d existing definitions\n", len(defs))
		return defs, nil
	}

	fmt.Printf("[DEBUG] Method: ListProtoDefinitionsByProfile - No definitions found, forcing parse of all proto paths\n")

	// Get all proto paths for this profile
	protoPaths, err := m.store.ListProtoPathsByServer(ctx, profileID)
	if err != nil {
		fmt.Printf("[DEBUG] Method: ListProtoDefinitionsByProfile - Failed to list proto paths: %v\n", err)
		return nil, fmt.Errorf("failed to list proto paths: %w", err)
	}

	// Force parse each proto path without hash check
	for _, protoPath := range protoPaths {
		fmt.Printf("[DEBUG] Forcing parse of proto path: %s\n", protoPath.Path)
		err := m.protoParser.ScanAndParseProtoPath(ctx, profileID, protoPath.ID, protoPath.Path)
		if err != nil {
			fmt.Printf("[ERROR] Failed to parse proto path %s: %v\n", protoPath.Path, err)
			continue // Continue with other paths even if one fails
		}

		// Update the hash after successful parse
		hash, err := calculateProtoPathHash(protoPath.Path)
		if err != nil {
			fmt.Printf("[ERROR] Failed to calculate hash for %s: %v\n", protoPath.Path, err)
			continue
		}

		protoPath.Hash = hash
		protoPath.LastScanned = time.Now()
		if err := m.store.UpdateProtoPath(ctx, protoPath); err != nil {
			fmt.Printf("[ERROR] Failed to update proto path hash: %v\n", err)
		}
	}

	// Return the newly parsed definitions
	return m.store.ListProtoDefinitionsByProfile(ctx, profileID)
}

func (m *ServerProfileManager) scanAndParseProtoPath(ctx context.Context, serverProfileId string, protoPathId string, path string) error {
	fmt.Printf("[DEBUG] Scanning proto path: %s\n", path)

	// Calculate hash of all proto files in the directory
	hash, err := calculateProtoPathHash(path)
	if err != nil {
		return fmt.Errorf("failed to calculate proto path hash: %w", err)
	}

	// Get existing proto path
	protoPath, err := m.store.GetProtoPath(ctx, protoPathId)
	if err != nil {
		return fmt.Errorf("failed to get proto path: %w", err)
	}

	// If hash matches and last scan was recent (within 5 minutes), skip parsing
	if protoPath != nil && protoPath.Hash == hash && time.Since(protoPath.LastScanned) < 5*time.Minute {
		fmt.Printf("[DEBUG] Proto path %s is up to date (hash: %s), skipping parse\n", path, hash)
		return nil
	}

	// Parse proto files
	err = m.protoParser.ScanAndParseProtoPath(ctx, serverProfileId, protoPathId, path)
	if err != nil {
		return fmt.Errorf("failed to parse proto files: %w", err)
	}

	// Update proto path with new hash and timestamp
	if protoPath == nil {
		protoPath = &proto.ProtoPath{
			ID:              protoPathId,
			ServerProfileID: serverProfileId,
			Path:            path,
		}
	}
	protoPath.Hash = hash
	protoPath.LastScanned = time.Now()

	if err := m.store.UpdateProtoPath(ctx, protoPath); err != nil {
		return fmt.Errorf("failed to update proto path: %w", err)
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

// Get returns a server profile by ID
func (m *ServerProfileManager) Get(ctx context.Context, id string) (*models.ServerProfile, error) {
	profile, err := m.store.Get(ctx, id)
	if err != nil {
		return nil, err
	}

	// Check if we have any proto definitions for this server
	_, err = m.store.ListProtoDefinitionsByProfile(ctx, id)
	if err != nil {
		fmt.Printf("[DEBUG] Failed to list proto definitions: %v\n", err)
	}

	return profile, nil
}

// Update updates a server profile
func (m *ServerProfileManager) Update(ctx context.Context, profile *models.ServerProfile) error {
	if err := profile.Validate(); err != nil {
		return err
	}

	// Check if we have any proto definitions for this server
	defs, err := m.store.ListProtoDefinitionsByProfile(ctx, profile.ID)
	if err != nil {
		fmt.Printf("[DEBUG] Failed to list proto definitions: %v\n", err)
		// Continue with update even if we can't check definitions
	} else if len(defs) == 0 {
		fmt.Printf("[DEBUG] No proto definitions found for server %s, attempting to parse proto paths\n", profile.ID)
		paths, err := m.store.ListProtoPathsByServer(ctx, profile.ID)
		if err != nil {
			fmt.Printf("[DEBUG] Failed to list proto paths: %v\n", err)
		} else {
			for _, path := range paths {
				fmt.Printf("[DEBUG] Parsing proto path: %s\n", path.Path)
				err = m.protoParser.ScanAndParseProtoPath(ctx, profile.ID, path.ID, path.Path)
				if err != nil {
					fmt.Printf("[DEBUG] Failed to parse proto path %s: %v\n", path.Path, err)
					// Continue with other paths even if one fails
					continue
				}
			}
		}
	}

	return m.store.Update(ctx, profile)
}

// Create creates a new server profile
func (m *ServerProfileManager) Create(ctx context.Context, profile *models.ServerProfile) error {
	if err := profile.Validate(); err != nil {
		return err
	}

	err := m.store.Create(ctx, profile)
	if err != nil {
		return err
	}

	// After creating the profile, check if it has any proto paths
	paths, err := m.store.ListProtoPathsByServer(ctx, profile.ID)
	if err != nil {
		fmt.Printf("[DEBUG] Failed to list proto paths: %v\n", err)
		return nil // Return success even if we can't parse paths
	}

	// Parse all proto paths for the new profile
	for _, path := range paths {
		fmt.Printf("[DEBUG] Parsing proto path: %s\n", path.Path)
		err = m.protoParser.ScanAndParseProtoPath(ctx, profile.ID, path.ID, path.Path)
		if err != nil {
			fmt.Printf("[DEBUG] Failed to parse proto path %s: %v\n", path.Path, err)
			// Continue with other paths even if one fails
			continue
		}
	}

	return nil
}

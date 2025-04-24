package services

import (
	"context"
	"fmt"
	"sync"

	"google.golang.org/grpc"
)

// ServerProfileManager handles server profile operations and maintains active connections
type ServerProfileManager struct {
	store         ServerProfileStore
	grpcClient    *GRPCClientManager
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

	if err := m.grpcClient.Connect(ctx, target, profile.TLSEnabled, certPath); err != nil {
		return fmt.Errorf("failed to connect: %w", err)
	}

	conn, err := m.grpcClient.GetConnection(target)
	if err != nil {
		return fmt.Errorf("failed to get connection: %w", err)
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

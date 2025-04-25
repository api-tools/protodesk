package services

import (
	"context"
	"fmt"
	"testing"

	"protodesk/pkg/models"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"
)

// mockGRPCClientManager is a mock implementation of GRPCClientManager
type mockGRPCClientManager struct {
	connections map[string]*grpc.ClientConn
	connectErr  error
}

var _ GRPCClientManager = (*mockGRPCClientManager)(nil) // Verify interface implementation

func newMockGRPCClientManager() GRPCClientManager {
	return &mockGRPCClientManager{
		connections: make(map[string]*grpc.ClientConn),
	}
}

func (m *mockGRPCClientManager) Connect(ctx context.Context, target string, useTLS bool, certPath string) error {
	if m.connectErr != nil {
		return m.connectErr
	}
	m.connections[target] = &grpc.ClientConn{}
	return nil
}

func (m *mockGRPCClientManager) Disconnect(target string) error {
	delete(m.connections, target)
	return nil
}

func (m *mockGRPCClientManager) GetConnection(target string) (*grpc.ClientConn, error) {
	if conn, ok := m.connections[target]; ok {
		return conn, nil
	}
	return nil, fmt.Errorf("connection not found")
}

func setupTestManager(t *testing.T) (*ServerProfileManager, *SQLiteStore, func()) {
	store, cleanup := setupTestStore(t)
	manager := NewServerProfileManager(store)
	manager.grpcClient = newMockGRPCClientManager()
	return manager, store, cleanup
}

func TestNewServerProfileManager(t *testing.T) {
	store, cleanup := setupTestStore(t)
	defer cleanup()

	manager := NewServerProfileManager(store)
	assert.NotNil(t, manager)
	assert.Equal(t, store, manager.GetStore())
	assert.NotNil(t, manager.grpcClient)
	assert.NotNil(t, manager.activeClients)
}

func TestServerProfileManager_ConnectionOperations(t *testing.T) {
	manager, store, cleanup := setupTestManager(t)
	defer cleanup()

	ctx := context.Background()

	// Create a test profile
	profile := models.NewServerProfile("test-server", "localhost", 50051)
	require.NoError(t, store.Create(ctx, profile))

	// Test initial state
	assert.False(t, manager.IsConnected(profile.ID))

	// Test Connect
	err := manager.Connect(ctx, profile.ID)
	require.NoError(t, err)
	assert.True(t, manager.IsConnected(profile.ID))

	// Test GetConnection
	conn, err := manager.GetConnection(profile.ID)
	require.NoError(t, err)
	assert.NotNil(t, conn)

	// Test Disconnect
	err = manager.Disconnect(ctx, profile.ID)
	require.NoError(t, err)
	assert.False(t, manager.IsConnected(profile.ID))

	// Test GetConnection after disconnect
	_, err = manager.GetConnection(profile.ID)
	assert.Error(t, err)
}

func TestServerProfileManager_DisconnectAll(t *testing.T) {
	manager, store, cleanup := setupTestManager(t)
	defer cleanup()

	ctx := context.Background()

	// Create and connect multiple profiles
	profiles := []*models.ServerProfile{
		models.NewServerProfile("server1", "localhost", 50051),
		models.NewServerProfile("server2", "localhost", 50052),
		models.NewServerProfile("server3", "localhost", 50053),
	}

	for _, p := range profiles {
		require.NoError(t, store.Create(ctx, p))
		require.NoError(t, manager.Connect(ctx, p.ID))
		assert.True(t, manager.IsConnected(p.ID))
	}

	// Test DisconnectAll
	manager.DisconnectAll()

	// Verify all connections are closed
	for _, p := range profiles {
		assert.False(t, manager.IsConnected(p.ID))
		_, err := manager.GetConnection(p.ID)
		assert.Error(t, err)
	}
}

func TestServerProfileManager_ConnectionErrors(t *testing.T) {
	manager, store, cleanup := setupTestManager(t)
	defer cleanup()

	ctx := context.Background()

	// Test connecting to non-existent profile
	err := manager.Connect(ctx, "non-existent")
	assert.Error(t, err)

	// Test disconnecting non-existent profile
	err = manager.Disconnect(ctx, "non-existent")
	assert.Error(t, err)

	// Test getting connection for non-existent profile
	_, err = manager.GetConnection("non-existent")
	assert.Error(t, err)

	// Test connection failure
	profile := models.NewServerProfile("test-server", "localhost", 50051)
	require.NoError(t, store.Create(ctx, profile))

	mock := newMockGRPCClientManager().(*mockGRPCClientManager)
	mock.connectErr = fmt.Errorf("connection failed")
	manager.grpcClient = mock

	err = manager.Connect(ctx, profile.ID)
	assert.Error(t, err)
	assert.False(t, manager.IsConnected(profile.ID))
}

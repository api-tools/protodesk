package services

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestNewGRPCClientManager(t *testing.T) {
	manager := NewGRPCClientManager()
	assert.NotNil(t, manager)
	assert.NotNil(t, manager.connections)
	assert.Empty(t, manager.connections)
}

func TestDefaultGRPCClientManager_ConnectionOperations(t *testing.T) {
	manager := NewGRPCClientManager()
	ctx := context.Background()

	// Test initial state
	_, err := manager.GetConnection("test-server")
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "no connection found")

	// Test insecure connection
	err = manager.Connect(ctx, "localhost:50051", false, "")
	require.NoError(t, err)

	// Test getting connection
	conn, err := manager.GetConnection("localhost:50051")
	require.NoError(t, err)
	assert.NotNil(t, conn)

	// Test disconnecting
	err = manager.Disconnect("localhost:50051")
	require.NoError(t, err)

	// Verify connection is removed
	_, err = manager.GetConnection("localhost:50051")
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "no connection found")
}

func TestDefaultGRPCClientManager_TLSConnection(t *testing.T) {
	manager := NewGRPCClientManager()
	ctx := context.Background()

	// Test TLS without certificate
	err := manager.Connect(ctx, "localhost:50051", true, "")
	require.NoError(t, err)

	// Test TLS with certificate (should fail as not implemented)
	err = manager.Connect(ctx, "localhost:50052", true, "cert.pem")
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "custom certificates not implemented")
}

func TestDefaultGRPCClientManager_DisconnectNonExistent(t *testing.T) {
	manager := NewGRPCClientManager()

	// Test disconnecting non-existent connection
	err := manager.Disconnect("non-existent")
	assert.NoError(t, err) // Should not return error as per current implementation
}

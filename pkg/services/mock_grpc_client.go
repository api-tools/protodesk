package services

import (
	"context"

	"google.golang.org/grpc"
)

// MockGRPCClientManager is a mock implementation of GRPCClientManager for testing
type MockGRPCClientManager struct {
	ConnectFunc       func(ctx context.Context, target string, useTLS bool, certPath string) error
	DisconnectFunc    func(target string) error
	GetConnectionFunc func(target string) (*grpc.ClientConn, error)
}

// Connect calls the mock ConnectFunc if set
func (m *MockGRPCClientManager) Connect(ctx context.Context, target string, useTLS bool, certPath string) error {
	if m.ConnectFunc != nil {
		return m.ConnectFunc(ctx, target, useTLS, certPath)
	}
	return nil
}

// Disconnect calls the mock DisconnectFunc if set
func (m *MockGRPCClientManager) Disconnect(target string) error {
	if m.DisconnectFunc != nil {
		return m.DisconnectFunc(target)
	}
	return nil
}

// GetConnection calls the mock GetConnectionFunc if set
func (m *MockGRPCClientManager) GetConnection(target string) (*grpc.ClientConn, error) {
	if m.GetConnectionFunc != nil {
		return m.GetConnectionFunc(target)
	}
	return &grpc.ClientConn{}, nil
}

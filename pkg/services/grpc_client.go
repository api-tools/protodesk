package services

import (
	"context"
	"crypto/tls"
	"fmt"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
)

// GRPCClientManager defines the interface for managing gRPC client connections
type GRPCClientManager interface {
	Connect(ctx context.Context, target string, useTLS bool, certPath string) error
	Disconnect(target string) error
	GetConnection(target string) (*grpc.ClientConn, error)
}

// DefaultGRPCClientManager manages gRPC client connections
type DefaultGRPCClientManager struct {
	connections map[string]*grpc.ClientConn
}

// NewGRPCClientManager creates a new DefaultGRPCClientManager
func NewGRPCClientManager() *DefaultGRPCClientManager {
	return &DefaultGRPCClientManager{
		connections: make(map[string]*grpc.ClientConn),
	}
}

// Connect establishes a gRPC connection to the specified server
func (m *DefaultGRPCClientManager) Connect(ctx context.Context, target string, useTLS bool, certPath string) error {
	var opts []grpc.DialOption

	if useTLS {
		if certPath != "" {
			// TODO: Implement custom certificate loading
			return fmt.Errorf("custom certificates not implemented yet")
		}
		opts = append(opts, grpc.WithTransportCredentials(credentials.NewTLS(&tls.Config{})))
	} else {
		opts = append(opts, grpc.WithTransportCredentials(insecure.NewCredentials()))
	}

	conn, err := grpc.DialContext(ctx, target, opts...)
	if err != nil {
		return fmt.Errorf("failed to connect: %w", err)
	}

	m.connections[target] = conn
	return nil
}

// Disconnect closes the connection to the specified server
func (m *DefaultGRPCClientManager) Disconnect(target string) error {
	if conn, exists := m.connections[target]; exists {
		err := conn.Close()
		if err != nil {
			return fmt.Errorf("failed to close connection: %w", err)
		}
		delete(m.connections, target)
	}
	return nil
}

// GetConnection returns an existing connection for the specified target
func (m *DefaultGRPCClientManager) GetConnection(target string) (*grpc.ClientConn, error) {
	if conn, exists := m.connections[target]; exists {
		return conn, nil
	}
	return nil, fmt.Errorf("no connection found for target: %s", target)
}

package services

import (
	"context"
	"crypto/tls"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/jhump/protoreflect/desc"
	"github.com/jhump/protoreflect/grpcreflect"
	"google.golang.org/grpc"
	"google.golang.org/grpc/connectivity"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	reflectpb "google.golang.org/grpc/reflection/grpc_reflection_v1alpha"
	"google.golang.org/protobuf/types/descriptorpb"
)

// GRPCClientManager defines the interface for managing gRPC client connections
type GRPCClientManager interface {
	Connect(ctx context.Context, target string, useTLS bool, certPath string) error
	Disconnect(target string) error
	GetConnection(target string) (*grpc.ClientConn, error)
	ListServicesAndMethods(conn *grpc.ClientConn) (map[string][]string, error)
	GetMethodInputDescriptor(conn *grpc.ClientConn, serviceName, methodName string) ([]FieldDescriptor, error)
}

// DefaultGRPCClientManager manages gRPC client connections
type DefaultGRPCClientManager struct {
	connections map[string]*grpc.ClientConn
	contexts    map[string]context.Context
}

// NewGRPCClientManager creates a new DefaultGRPCClientManager
func NewGRPCClientManager() *DefaultGRPCClientManager {
	return &DefaultGRPCClientManager{
		connections: make(map[string]*grpc.ClientConn),
		contexts:    make(map[string]context.Context),
	}
}

// debugPrintConnections prints the current state of all connections
func (m *DefaultGRPCClientManager) debugPrintConnections() {
	// Remove or comment out all fmt.Printf debug/info lines except warnings/errors
}

// Connect establishes a gRPC connection to the specified server
func (m *DefaultGRPCClientManager) Connect(ctx context.Context, target string, useTLS bool, certPath string) error {
	// Remove or comment out all fmt.Printf debug/info lines except warnings/errors
	var opts []grpc.DialOption

	// Add default options for HTTP/2
	opts = append(opts,
		grpc.WithDefaultServiceConfig(`{"loadBalancingPolicy":"round_robin"}`),
		grpc.WithNoProxy(),
		grpc.WithBlock(), // Block until connection is established
	)

	if useTLS {
		if certPath != "" {
			// TODO: Implement custom certificate loading
			return fmt.Errorf("custom certificates not implemented yet")
		}
		// Use system root certificates with more permissive settings for production servers
		opts = append(opts, grpc.WithTransportCredentials(credentials.NewTLS(&tls.Config{
			MinVersion: tls.VersionTLS12,
			// Allow insecure renegotiation for compatibility with some servers
			Renegotiation: tls.RenegotiateOnceAsClient,
			// Don't verify hostname for production servers that might use load balancers
			InsecureSkipVerify: true,
		})))
	} else {
		opts = append(opts, grpc.WithTransportCredentials(insecure.NewCredentials()))
	}

	// Create a timeout context for the connection attempt
	timeoutCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	// Create connection
	conn, err := grpc.DialContext(timeoutCtx, target, opts...)
	if err != nil {
		if err == context.DeadlineExceeded {
			return fmt.Errorf("connection timeout: server at %s did not respond within 5 seconds. Please check if the server is running and accessible", target)
		}
		return fmt.Errorf("failed to connect to %s: %w", target, err)
	}

	// Wait for connection to be ready
	ready := make(chan struct{})
	go func() {
		for {
			state := conn.GetState()
			if state == connectivity.Ready {
				close(ready)
				return
			}
			if state == connectivity.Shutdown || state == connectivity.TransientFailure {
				return
			}
			time.Sleep(100 * time.Millisecond)
		}
	}()

	select {
	case <-ready:
		// Connection is ready - store the original context without timeout
		m.connections[target] = conn
		m.contexts[target] = ctx
		return nil
	case <-timeoutCtx.Done():
		// Context timed out or was cancelled
		conn.Close()
		if timeoutCtx.Err() == context.DeadlineExceeded {
			return fmt.Errorf("connection timeout: server at %s did not become ready within 5 seconds. Please check if the server is running and accessible", target)
		}
		return fmt.Errorf("connection cancelled: %w", timeoutCtx.Err())
	}
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

// findProtobufIncludePath finds the protobuf include path by running protoc --version
func findProtobufIncludePath() (string, error) {
	// First try to get the version from protoc
	cmd := exec.Command("protoc", "--version")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("failed to get protoc version: %w", err)
	}

	// Try common locations based on the OS
	locations := []string{
		"/usr/local/include",                   // Linux/Unix default
		"/usr/include",                         // Linux/Unix alternative
		"/opt/homebrew/include",                // macOS Homebrew
		"/opt/homebrew/Cellar/protobuf",        // macOS Homebrew Cellar
		"C:\\Program Files\\protobuf\\include", // Windows
	}

	// Check each location
	for _, loc := range locations {
		// Check if google/protobuf/timestamp.proto exists in this location
		timestampPath := filepath.Join(loc, "google", "protobuf", "timestamp.proto")
		if _, err := os.Stat(timestampPath); err == nil {
			return loc, nil
		}
	}

	// If we couldn't find it in common locations, try to get it from protoc
	cmd = exec.Command("which", "protoc")
	output, err = cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("failed to find protoc: %w", err)
	}
	protocPath := string(output)
	protocPath = protocPath[:len(protocPath)-1] // Remove newline

	// Try to find include directory relative to protoc
	possiblePaths := []string{
		filepath.Join(filepath.Dir(protocPath), "..", "include"),
		filepath.Join(filepath.Dir(protocPath), "..", "..", "include"),
	}

	for _, path := range possiblePaths {
		timestampPath := filepath.Join(path, "google", "protobuf", "timestamp.proto")
		if _, err := os.Stat(timestampPath); err == nil {
			return path, nil
		}
	}

	return "", fmt.Errorf("could not find protobuf include path")
}

// ListServicesAndMethods uses gRPC reflection to list all services and their methods for a given connection
func (m *DefaultGRPCClientManager) ListServicesAndMethods(conn *grpc.ClientConn) (map[string][]string, error) {
	// Find the context for this connection
	var ctx context.Context
	for t, storedConn := range m.connections {
		if storedConn == conn {
			ctx = m.contexts[t]
			break
		}
	}
	if ctx == nil {
		ctx = context.Background()
	}

	// Create a reflection client with the context that has headers
	rc := grpcreflect.NewClient(ctx, reflectpb.NewServerReflectionClient(conn))
	defer rc.Reset()

	// First, try to list services
	services, err := rc.ListServices()
	if err != nil {
		return nil, fmt.Errorf("failed to list services: %w", err)
	}

	result := make(map[string][]string)
	for _, service := range services {
		// Get service descriptor
		svcDesc, err := rc.ResolveService(service)
		if err != nil {
			// Add the service with an empty methods list
			result[service] = []string{}
			continue
		}

		// Get methods
		methods := make([]string, 0)
		for _, method := range svcDesc.GetMethods() {
			methods = append(methods, method.GetName())
		}

		result[service] = methods
	}

	return result, nil
}

type FieldDescriptor struct {
	Name       string            `json:"name"`
	Type       string            `json:"type"`
	IsRepeated bool              `json:"isRepeated"`
	EnumValues []string          `json:"enumValues,omitempty"`
	Fields     []FieldDescriptor `json:"fields,omitempty"`
}

func protoTypeToString(t descriptorpb.FieldDescriptorProto_Type) string {
	switch t {
	case descriptorpb.FieldDescriptorProto_TYPE_DOUBLE:
		return "double"
	case descriptorpb.FieldDescriptorProto_TYPE_FLOAT:
		return "float"
	case descriptorpb.FieldDescriptorProto_TYPE_INT64:
		return "int64"
	case descriptorpb.FieldDescriptorProto_TYPE_UINT64:
		return "uint64"
	case descriptorpb.FieldDescriptorProto_TYPE_INT32:
		return "int32"
	case descriptorpb.FieldDescriptorProto_TYPE_FIXED64:
		return "fixed64"
	case descriptorpb.FieldDescriptorProto_TYPE_FIXED32:
		return "fixed32"
	case descriptorpb.FieldDescriptorProto_TYPE_BOOL:
		return "bool"
	case descriptorpb.FieldDescriptorProto_TYPE_STRING:
		return "string"
	case descriptorpb.FieldDescriptorProto_TYPE_BYTES:
		return "bytes"
	case descriptorpb.FieldDescriptorProto_TYPE_UINT32:
		return "uint32"
	case descriptorpb.FieldDescriptorProto_TYPE_SFIXED32:
		return "sfixed32"
	case descriptorpb.FieldDescriptorProto_TYPE_SFIXED64:
		return "sfixed64"
	case descriptorpb.FieldDescriptorProto_TYPE_SINT32:
		return "sint32"
	case descriptorpb.FieldDescriptorProto_TYPE_SINT64:
		return "sint64"
	case descriptorpb.FieldDescriptorProto_TYPE_ENUM:
		return "enum"
	case descriptorpb.FieldDescriptorProto_TYPE_MESSAGE:
		return "message"
	case descriptorpb.FieldDescriptorProto_TYPE_GROUP:
		return "group"
	default:
		return t.String()
	}
}

// Helper to recursively build FieldDescriptor for a message type
func buildFieldDescriptors(msgDesc *desc.MessageDescriptor) []FieldDescriptor {
	fields := msgDesc.GetFields()
	var result []FieldDescriptor
	for _, f := range fields {
		fd := FieldDescriptor{
			Name:       f.GetName(),
			Type:       protoTypeToString(f.GetType()),
			IsRepeated: f.IsRepeated(),
		}
		if f.GetType() == descriptorpb.FieldDescriptorProto_TYPE_ENUM && f.GetEnumType() != nil {
			enumDesc := f.GetEnumType()
			for _, v := range enumDesc.GetValues() {
				fd.EnumValues = append(fd.EnumValues, v.GetName())
			}
		}
		if f.GetType() == descriptorpb.FieldDescriptorProto_TYPE_MESSAGE && f.GetMessageType() != nil {
			// Recursively build subfields for message type
			fd.Fields = buildFieldDescriptors(f.GetMessageType())
		}
		result = append(result, fd)
	}
	return result
}

// GetMethodInputDescriptor uses reflection to get the input type fields for a given service/method
func (m *DefaultGRPCClientManager) GetMethodInputDescriptor(conn *grpc.ClientConn, serviceName, methodName string) ([]FieldDescriptor, error) {
	ctx := context.Background()
	rc := grpcreflect.NewClient(ctx, reflectpb.NewServerReflectionClient(conn))
	defer rc.Reset()

	svcDesc, err := rc.ResolveService(serviceName)
	if err != nil {
		return nil, err
	}
	mDesc := svcDesc.FindMethodByName(methodName)
	if mDesc == nil {
		return nil, fmt.Errorf("method not found: %s", methodName)
	}
	inputType := mDesc.GetInputType()
	// Use the recursive helper for the top-level message
	return buildFieldDescriptors(inputType), nil
}

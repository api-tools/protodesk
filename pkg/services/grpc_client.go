package services

import (
	"context"
	"crypto/tls"
	"fmt"

	"github.com/jhump/protoreflect/grpcreflect"
	"google.golang.org/grpc"
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

// ListServicesAndMethods uses gRPC reflection to list all services and their methods for a given connection
func (m *DefaultGRPCClientManager) ListServicesAndMethods(conn *grpc.ClientConn) (map[string][]string, error) {
	ctx := context.Background()
	rc := grpcreflect.NewClient(ctx, reflectpb.NewServerReflectionClient(conn))
	defer rc.Reset()

	services, err := rc.ListServices()
	if err != nil {
		return nil, fmt.Errorf("reflection not supported or failed: %w", err)
	}

	result := make(map[string][]string)
	for _, svc := range services {
		if svc == "grpc.reflection.v1alpha.ServerReflection" {
			continue
		}
		svcDesc, err := rc.ResolveService(svc)
		if err != nil {
			continue // skip services we can't resolve
		}
		var methods []string
		for _, m := range svcDesc.GetMethods() {
			methods = append(methods, m.GetName())
		}
		result[svc] = methods
	}
	return result, nil
}

type FieldDescriptor struct {
	Name       string   `json:"name"`
	Type       string   `json:"type"`
	IsRepeated bool     `json:"isRepeated"`
	EnumValues []string `json:"enumValues,omitempty"`
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
	fields := inputType.GetFields()
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
		result = append(result, fd)
	}
	return result, nil
}

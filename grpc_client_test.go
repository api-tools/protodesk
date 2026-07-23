package main

import (
	"context"
	"net"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jhump/protoreflect/desc/protoparse"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/interop/grpc_testing"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/reflection"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

type testService struct {
	grpc_testing.UnimplementedTestServiceServer
}

type protoOnlyTestService interface {
	Ping(context.Context, *emptypb.Empty) (*emptypb.Empty, error)
}

type protoOnlyTestServer struct{}

func (s *protoOnlyTestServer) Ping(context.Context, *emptypb.Empty) (*emptypb.Empty, error) {
	return &emptypb.Empty{}, nil
}

func protoOnlyPingHandler(srv interface{}, ctx context.Context, decode func(interface{}) error, interceptor grpc.UnaryServerInterceptor) (interface{}, error) {
	request := &emptypb.Empty{}
	if err := decode(request); err != nil {
		return nil, err
	}
	if interceptor == nil {
		return srv.(protoOnlyTestService).Ping(ctx, request)
	}
	info := &grpc.UnaryServerInfo{Server: srv, FullMethod: "/protoonly.TestService/Ping"}
	handler := func(ctx context.Context, req interface{}) (interface{}, error) {
		return srv.(protoOnlyTestService).Ping(ctx, req.(*emptypb.Empty))
	}
	return interceptor(ctx, request, info, handler)
}

func (s *testService) EmptyCall(ctx context.Context, req *grpc_testing.Empty) (*grpc_testing.Empty, error) {
	_ = grpc.SendHeader(ctx, metadata.Pairs("x-test-header", "seen"))
	return &grpc_testing.Empty{}, nil
}

func (s *testService) UnaryCall(ctx context.Context, req *grpc_testing.SimpleRequest) (*grpc_testing.SimpleResponse, error) {
	if req.GetResponseSize() == 404 {
		return nil, status.Error(codes.NotFound, "requested response not found")
	}
	return &grpc_testing.SimpleResponse{
		Payload: &grpc_testing.Payload{
			Type: grpc_testing.PayloadType_COMPRESSABLE,
			Body: []byte("hello"),
		},
	}, nil
}

func startTestServer(t *testing.T, withReflection bool) string {
	t.Helper()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}

	server := grpc.NewServer()
	grpc_testing.RegisterTestServiceServer(server, &testService{})
	if withReflection {
		reflection.Register(server)
	}

	go func() {
		_ = server.Serve(listener)
	}()
	t.Cleanup(func() {
		server.Stop()
		_ = listener.Close()
	})

	return listener.Addr().String()
}

func startProtoOnlyTestServer(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	server := grpc.NewServer()
	server.RegisterService(&grpc.ServiceDesc{
		ServiceName: "protoonly.TestService",
		HandlerType: (*protoOnlyTestService)(nil),
		Methods: []grpc.MethodDesc{{
			MethodName: "Ping",
			Handler:    protoOnlyPingHandler,
		}},
	}, &protoOnlyTestServer{})
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() {
		server.Stop()
		_ = listener.Close()
	})
	return listener.Addr().String()
}

func writeProtoOnlySchema(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "proto_only.proto")
	writeTestFile(t, path, `
syntax = "proto3";
package protoonly;
import "google/protobuf/empty.proto";
service TestService {
  rpc Ping(google.protobuf.Empty) returns (google.protobuf.Empty);
}
`)
	return path
}

func TestValidateServerAddress(t *testing.T) {
	for _, address := range []string{"", "localhost", "http://localhost:50051"} {
		if err := validateServerAddress(address); err == nil {
			t.Fatalf("expected %q to be invalid", address)
		}
	}
	if err := validateServerAddress("localhost:50051"); err != nil {
		t.Fatalf("expected host:port to be valid: %v", err)
	}
}

func TestConnectDiscoversReflectionServices(t *testing.T) {
	client := newGRPCClient()
	response, err := client.Connect(context.Background(), ConnectRequest{
		ServerAddress:     startTestServer(t, true),
		ReflectionEnabled: true,
	})
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	if response.State != "connected" {
		t.Fatalf("expected connected state, got %q", response.State)
	}
	if len(response.Services) != 1 {
		t.Fatalf("expected one service, got %#v", response.Services)
	}
	if response.Services[0].Name != "grpc.testing.TestService" {
		t.Fatalf("unexpected service %q", response.Services[0].Name)
	}

	foundUnary := false
	foundStreaming := false
	for _, method := range response.Services[0].Methods {
		if method.FullName == grpc_testing.TestService_UnaryCall_FullMethodName {
			foundUnary = true
		}
		if method.FullName == grpc_testing.TestService_StreamingOutputCall_FullMethodName && method.ServerStreaming {
			foundStreaming = true
		}
	}
	if !foundUnary || !foundStreaming {
		t.Fatalf("expected unary and streaming methods in %#v", response.Services[0].Methods)
	}
	for _, method := range response.Services[0].Methods {
		if method.FullName == grpc_testing.TestService_UnaryCall_FullMethodName && len(method.RequestFields) == 0 {
			t.Fatalf("expected unary method to include request fields")
		}
	}
}

func TestDescribeMessageTypesCollectsNestedSchemasAndStopsAtCycles(t *testing.T) {
	parser := protoparse.Parser{Accessor: protoparse.FileContentsFromMap(map[string]string{
		"recursive.proto": `
syntax = "proto3";
package registry;

message Root {
  Node node = 1;
}

message Node {
  enum State {
    UNKNOWN = 0;
    READY = 1;
  }
  string name = 1;
  State state = 2;
  Node next = 3;
}
`,
	})}
	files, err := parser.ParseFiles("recursive.proto")
	if err != nil {
		t.Fatalf("parse descriptor: %v", err)
	}
	root := files[0].FindMessage("registry.Root")
	messageTypes := describeMessageTypes(root)

	if len(messageTypes) != 2 {
		t.Fatalf("expected root and node schemas, got %#v", messageTypes)
	}
	node, ok := messageTypes["registry.Node"]
	if !ok {
		t.Fatalf("expected nested node schema, got %#v", messageTypes)
	}
	if len(node.Fields) != 3 {
		t.Fatalf("expected three node fields, got %#v", node.Fields)
	}
	if node.Fields[1].Type != "enum" || len(node.Fields[1].EnumValues) != 2 {
		t.Fatalf("expected nested enum values, got %#v", node.Fields[1])
	}
	if node.Fields[2].MessageType != "registry.Node" {
		t.Fatalf("expected recursive message reference, got %#v", node.Fields[2])
	}
}

func TestConnectKeepsConnectionWhenReflectionUnavailable(t *testing.T) {
	client := newGRPCClient()
	response, err := client.Connect(context.Background(), ConnectRequest{
		ServerAddress:     startTestServer(t, false),
		ReflectionEnabled: true,
	})
	if err != nil {
		t.Fatalf("reflection failure should not fail connect: %v", err)
	}
	if response.State != "connected" || !response.ReflectionUnavailable {
		t.Fatalf("expected connected with reflection unavailable, got %#v", response)
	}
}

func TestConnectDiscoversAndInvokesFromProtoFilesWithoutReflection(t *testing.T) {
	client := newGRPCClient()
	response, err := client.Connect(context.Background(), ConnectRequest{
		ServerAddress:     startProtoOnlyTestServer(t),
		ReflectionEnabled: false,
		ProtoFiles:        []string{writeProtoOnlySchema(t)},
	})
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	if response.DescriptorSource != "proto" || len(response.Services) != 1 {
		t.Fatalf("expected proto services, got %#v", response)
	}
	if response.Services[0].Name != "protoonly.TestService" || len(response.Services[0].Methods) != 1 {
		t.Fatalf("unexpected proto service model: %#v", response.Services)
	}

	invokeResponse, err := client.Invoke(context.Background(), InvokeRequest{
		FullMethod: "/protoonly.TestService/Ping",
		BodyJSON:   "{}",
		TimeoutMs:  1000,
	})
	if err != nil {
		t.Fatalf("invoke: %v", err)
	}
	if !invokeResponse.OK || invokeResponse.StatusCode != "OK" {
		t.Fatalf("expected proto-backed invoke success, got %#v", invokeResponse)
	}
}

func TestConnectFallsBackToProtoFilesWhenReflectionUnavailable(t *testing.T) {
	client := newGRPCClient()
	response, err := client.Connect(context.Background(), ConnectRequest{
		ServerAddress:     startProtoOnlyTestServer(t),
		ReflectionEnabled: true,
		ProtoFiles:        []string{writeProtoOnlySchema(t)},
	})
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	if !response.ReflectionUnavailable || response.DescriptorSource != "proto" || len(response.Services) != 1 {
		t.Fatalf("expected reflection fallback to proto descriptors, got %#v", response)
	}
}

func TestConnectKeepsConnectionWhenProtoSourcesBecomeInvalid(t *testing.T) {
	invalidProto := filepath.Join(t.TempDir(), "invalid.proto")
	writeTestFile(t, invalidProto, `syntax = "proto3"; message Broken {`)
	client := newGRPCClient()
	response, err := client.Connect(context.Background(), ConnectRequest{
		ServerAddress: startProtoOnlyTestServer(t),
		ProtoFiles:    []string{invalidProto},
	})
	if err != nil {
		t.Fatalf("proto compilation should not fail an established connection: %v", err)
	}
	if response.State != "connected" || response.DescriptorSource != "none" || response.ProtoSourceError == "" {
		t.Fatalf("expected connected proto warning state, got %#v", response)
	}
}

func TestInvokeUnarySuccess(t *testing.T) {
	client := newGRPCClient()
	_, err := client.Connect(context.Background(), ConnectRequest{
		ServerAddress:     startTestServer(t, true),
		ReflectionEnabled: true,
	})
	if err != nil {
		t.Fatalf("connect: %v", err)
	}

	response, err := client.Invoke(context.Background(), InvokeRequest{
		FullMethod: grpc_testing.TestService_EmptyCall_FullMethodName,
		BodyJSON:   "{}",
		Metadata:   map[string]string{"x-request-id": "test-123"},
		TimeoutMs:  1000,
	})
	if err != nil {
		t.Fatalf("invoke: %v", err)
	}
	if !response.OK || response.StatusCode != "OK" {
		t.Fatalf("expected OK response, got %#v", response)
	}
	if response.ResponseMetadata["x-test-header"] != "seen" {
		t.Fatalf("expected response metadata, got %#v", response.ResponseMetadata)
	}
}

func TestInvokeUnaryError(t *testing.T) {
	client := newGRPCClient()
	_, err := client.Connect(context.Background(), ConnectRequest{
		ServerAddress:     startTestServer(t, true),
		ReflectionEnabled: true,
	})
	if err != nil {
		t.Fatalf("connect: %v", err)
	}

	response, err := client.Invoke(context.Background(), InvokeRequest{
		FullMethod: grpc_testing.TestService_UnaryCall_FullMethodName,
		BodyJSON:   `{"responseSize":404}`,
		TimeoutMs:  1000,
	})
	if err != nil {
		t.Fatalf("invoke: %v", err)
	}
	if response.OK || response.StatusCode != "NOT_FOUND" || !strings.Contains(response.Error, "requested response not found") {
		t.Fatalf("expected NOT_FOUND response, got %#v", response)
	}
}

func TestInvokeStreamingReturnsMVPError(t *testing.T) {
	client := newGRPCClient()
	_, err := client.Connect(context.Background(), ConnectRequest{
		ServerAddress:     startTestServer(t, true),
		ReflectionEnabled: true,
	})
	if err != nil {
		t.Fatalf("connect: %v", err)
	}

	response, err := client.Invoke(context.Background(), InvokeRequest{
		FullMethod: grpc_testing.TestService_StreamingOutputCall_FullMethodName,
		BodyJSON:   "{}",
		TimeoutMs:  1000,
	})
	if err != nil {
		t.Fatalf("invoke: %v", err)
	}
	if response.OK || response.StatusCode != "UNIMPLEMENTED" {
		t.Fatalf("expected streaming unimplemented response, got %#v", response)
	}
}

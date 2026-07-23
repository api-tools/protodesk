package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/golang/protobuf/proto"
	"github.com/jhump/protoreflect/desc"
	"github.com/jhump/protoreflect/dynamic"
	"github.com/jhump/protoreflect/dynamic/grpcdynamic"
	"github.com/jhump/protoreflect/grpcreflect"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/reflection/grpc_reflection_v1alpha"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/descriptorpb"
)

const defaultConnectTimeout = 5 * time.Second

type grpcClient struct {
	mu           sync.Mutex
	conn         *grpc.ClientConn
	reflection   *grpcreflect.Client
	services     []GrpcService
	methods      map[string]*desc.MethodDescriptor
	address      string
	tlsEnabled   bool
	reflectionOn bool
}

func newGRPCClient() *grpcClient {
	return &grpcClient{
		methods: map[string]*desc.MethodDescriptor{},
	}
}

func (c *grpcClient) Connect(ctx context.Context, req ConnectRequest) (ConnectResponse, error) {
	address := strings.TrimSpace(req.ServerAddress)
	if err := validateServerAddress(address); err != nil {
		return ConnectResponse{State: "failed", Error: err.Error()}, err
	}

	dialCtx, cancel := context.WithTimeout(ctx, defaultConnectTimeout)
	defer cancel()

	opts := []grpc.DialOption{grpc.WithBlock()}
	if req.TLSEnabled {
		opts = append(opts, grpc.WithTransportCredentials(credentials.NewTLS(&tls.Config{MinVersion: tls.VersionTLS12})))
	} else {
		opts = append(opts, grpc.WithTransportCredentials(insecure.NewCredentials()))
	}

	conn, err := grpc.DialContext(dialCtx, address, opts...)
	if err != nil {
		return ConnectResponse{State: "failed", Error: fmt.Sprintf("failed to connect to %s: %v", address, err)}, err
	}

	c.mu.Lock()
	c.closeLocked()
	c.conn = conn
	c.address = address
	c.tlsEnabled = req.TLSEnabled
	c.reflectionOn = req.ReflectionEnabled
	c.services = nil
	c.methods = map[string]*desc.MethodDescriptor{}
	c.mu.Unlock()

	if req.ReflectionEnabled {
		services, methods, reflectClient, reflectErr := discoverServices(ctx, conn, req.Metadata)
		c.mu.Lock()
		c.reflection = reflectClient
		c.mu.Unlock()
		if reflectErr == nil {
			c.installDescriptors(services, methods)
			return ConnectResponse{State: "connected", Services: services, DescriptorSource: "reflection"}, nil
		}

		reflectionError := fmt.Sprintf("server reflection is unavailable: %v", reflectErr)
		if hasProtoSources(req) {
			protoServices, protoMethods, protoErr := discoverProtoServices(ctx, req.ProtoFiles, req.ProtoFolders)
			if protoErr == nil {
				c.installDescriptors(protoServices, protoMethods)
				return ConnectResponse{
					State:                 "connected",
					Services:              protoServices,
					Error:                 reflectionError,
					ReflectionUnavailable: true,
					DescriptorSource:      "proto",
				}, nil
			}
			return ConnectResponse{
				State:                 "connected",
				Services:              []GrpcService{},
				Error:                 reflectionError,
				ReflectionUnavailable: true,
				DescriptorSource:      "none",
				ProtoSourceError:      protoErr.Error(),
			}, nil
		}

		return ConnectResponse{
			State:                 "connected",
			Services:              []GrpcService{},
			Error:                 reflectionError,
			ReflectionUnavailable: true,
			DescriptorSource:      "none",
		}, nil
	}

	if !hasProtoSources(req) {
		return ConnectResponse{State: "connected", Services: []GrpcService{}, DescriptorSource: "none"}, nil
	}
	services, methods, protoErr := discoverProtoServices(ctx, req.ProtoFiles, req.ProtoFolders)
	if protoErr != nil {
		return ConnectResponse{
			State:            "connected",
			Services:         []GrpcService{},
			DescriptorSource: "none",
			ProtoSourceError: protoErr.Error(),
		}, nil
	}
	c.installDescriptors(services, methods)
	return ConnectResponse{State: "connected", Services: services, DescriptorSource: "proto"}, nil
}

func (c *grpcClient) installDescriptors(services []GrpcService, methods map[string]*desc.MethodDescriptor) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.services = services
	c.methods = methods
}

func (c *grpcClient) Disconnect() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.closeLocked()
	c.address = ""
	c.tlsEnabled = false
	c.reflectionOn = false
	c.services = nil
	c.methods = map[string]*desc.MethodDescriptor{}
	return nil
}

func (c *grpcClient) ListServices() (ListServicesResponse, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return ListServicesResponse{Services: append([]GrpcService(nil), c.services...)}, nil
}

func (c *grpcClient) Invoke(ctx context.Context, req InvokeRequest) (InvokeResponse, error) {
	start := time.Now()
	timeout := time.Duration(req.TimeoutMs) * time.Millisecond
	if timeout <= 0 {
		timeout = 5 * time.Second
	}

	c.mu.Lock()
	conn := c.conn
	method := c.methods[req.FullMethod]
	c.mu.Unlock()

	if conn == nil {
		return invocationError("FAILED_PRECONDITION", "no server is connected", start), nil
	}
	if method == nil {
		return invocationError("NOT_FOUND", fmt.Sprintf("method %q is not available from the connected descriptors", req.FullMethod), start), nil
	}
	if method.IsClientStreaming() || method.IsServerStreaming() {
		return invocationError("UNIMPLEMENTED", "streaming invocation is not implemented in MVP", start), nil
	}

	callCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	if len(req.Metadata) > 0 {
		md := metadata.New(req.Metadata)
		callCtx = metadata.NewOutgoingContext(callCtx, md)
	}

	messageFactory := dynamic.NewMessageFactoryWithDefaults()
	requestMessage := dynamic.NewMessage(method.GetInputType())
	body := strings.TrimSpace(req.BodyJSON)
	if body == "" {
		body = "{}"
	}
	if err := requestMessage.UnmarshalJSON([]byte(body)); err != nil {
		return invocationError("INVALID_ARGUMENT", fmt.Sprintf("invalid JSON request body: %v", err), start), nil
	}

	var header metadata.MD
	var trailer metadata.MD
	callOptions := []grpc.CallOption{grpc.Header(&header), grpc.Trailer(&trailer)}
	if req.Authority != "" {
		callOptions = append(callOptions, grpc.CallAuthority(req.Authority))
	}

	responseMessage, err := grpcdynamic.NewStubWithMessageFactory(conn, messageFactory).InvokeRpc(callCtx, method, requestMessage, callOptions...)
	duration := time.Since(start).Milliseconds()
	if err != nil {
		st := status.Convert(err)
		return InvokeResponse{
			OK:               false,
			StatusCode:       grpcCodeName(st.Code()),
			StatusMessage:    st.Message(),
			DurationMs:       duration,
			ResponseMetadata: flattenMetadata(header, trailer),
			Error:            st.Message(),
		}, nil
	}

	bodyJSON, err := marshalDynamicResponse(responseMessage)
	if err != nil {
		return invocationError("INTERNAL", fmt.Sprintf("failed to serialize response JSON: %v", err), start), nil
	}

	return InvokeResponse{
		OK:               true,
		StatusCode:       "OK",
		DurationMs:       duration,
		BodyJSON:         bodyJSON,
		ResponseMetadata: flattenMetadata(header, trailer),
	}, nil
}

func (c *grpcClient) closeLocked() {
	if c.reflection != nil {
		c.reflection.Reset()
		c.reflection = nil
	}
	if c.conn != nil {
		_ = c.conn.Close()
		c.conn = nil
	}
}

func validateServerAddress(address string) error {
	if address == "" {
		return errors.New("server address is required")
	}
	host, port, err := net.SplitHostPort(address)
	if err != nil || host == "" || port == "" {
		return errors.New("server address must be in host:port format")
	}
	return nil
}

func hasProtoSources(req ConnectRequest) bool {
	return len(normalizePathList(req.ProtoFiles)) > 0 || len(normalizePathList(req.ProtoFolders)) > 0
}

func discoverServices(ctx context.Context, conn *grpc.ClientConn, requestMetadata map[string]string) ([]GrpcService, map[string]*desc.MethodDescriptor, *grpcreflect.Client, error) {
	if len(requestMetadata) > 0 {
		ctx = metadata.NewOutgoingContext(ctx, metadata.New(requestMetadata))
	}
	reflectClient := grpcreflect.NewClient(ctx, grpc_reflection_v1alpha.NewServerReflectionClient(conn))
	serviceNames, err := reflectClient.ListServices()
	if err != nil {
		return nil, nil, reflectClient, err
	}
	sort.Strings(serviceNames)

	serviceDescriptors := make([]*desc.ServiceDescriptor, 0, len(serviceNames))
	for _, serviceName := range serviceNames {
		if strings.HasPrefix(serviceName, "grpc.reflection.") {
			continue
		}
		serviceDescriptor, err := reflectClient.ResolveService(serviceName)
		if err != nil {
			return nil, nil, reflectClient, err
		}
		serviceDescriptors = append(serviceDescriptors, serviceDescriptor)
	}
	services, methodsByName, err := buildServiceModels(serviceDescriptors)
	return services, methodsByName, reflectClient, err
}

func discoverProtoServices(ctx context.Context, protoFiles []string, protoFolders []string) ([]GrpcService, map[string]*desc.MethodDescriptor, error) {
	compiledFiles, _, compileErrors := compileProtoSources(ctx, ValidateProtoSourcesRequest{
		ProtoFiles:   protoFiles,
		ProtoFolders: protoFolders,
	})
	if len(compileErrors) > 0 {
		return nil, nil, errors.New(strings.Join(compileErrors, "; "))
	}

	fileDescriptors := make([]protoreflect.FileDescriptor, 0, len(compiledFiles))
	for _, file := range compiledFiles {
		fileDescriptors = append(fileDescriptors, file)
	}
	wrappedFiles, err := desc.WrapFiles(fileDescriptors)
	if err != nil {
		return nil, nil, fmt.Errorf("load compiled proto descriptors: %w", err)
	}

	serviceByName := make(map[string]*desc.ServiceDescriptor)
	for _, file := range wrappedFiles {
		for _, service := range file.GetServices() {
			serviceByName[service.GetFullyQualifiedName()] = service
		}
	}
	serviceDescriptors := make([]*desc.ServiceDescriptor, 0, len(serviceByName))
	for _, service := range serviceByName {
		serviceDescriptors = append(serviceDescriptors, service)
	}
	return buildServiceModels(serviceDescriptors)
}

func buildServiceModels(serviceDescriptors []*desc.ServiceDescriptor) ([]GrpcService, map[string]*desc.MethodDescriptor, error) {
	sort.Slice(serviceDescriptors, func(i, j int) bool {
		return serviceDescriptors[i].GetFullyQualifiedName() < serviceDescriptors[j].GetFullyQualifiedName()
	})
	services := make([]GrpcService, 0, len(serviceDescriptors))
	methodsByName := make(map[string]*desc.MethodDescriptor)
	for _, serviceDescriptor := range serviceDescriptors {
		methods := serviceDescriptor.GetMethods()
		service := GrpcService{
			Name:    serviceDescriptor.GetFullyQualifiedName(),
			Methods: make([]GrpcMethod, 0, len(methods)),
		}
		for _, method := range methods {
			fullMethod := fmt.Sprintf("/%s/%s", service.Name, method.GetName())
			methodsByName[fullMethod] = method
			service.Methods = append(service.Methods, GrpcMethod{
				ServiceName:     service.Name,
				MethodName:      method.GetName(),
				FullName:        fullMethod,
				RequestType:     method.GetInputType().GetFullyQualifiedName(),
				ResponseType:    method.GetOutputType().GetFullyQualifiedName(),
				ClientStreaming: method.IsClientStreaming(),
				ServerStreaming: method.IsServerStreaming(),
				RequestFields:   describeFields(method.GetInputType()),
				MessageTypes:    describeMessageTypes(method.GetInputType()),
			})
		}
		services = append(services, service)
	}
	return services, methodsByName, nil
}

func describeFields(message *desc.MessageDescriptor) []GrpcField {
	if message == nil {
		return nil
	}

	fields := message.GetFields()
	out := make([]GrpcField, 0, len(fields))
	for _, field := range fields {
		fieldProto := field.AsFieldDescriptorProto()
		fieldType := strings.TrimPrefix(fieldProto.GetType().String(), "TYPE_")
		grpcField := GrpcField{
			Name:     field.GetName(),
			JSONName: jsonFieldName(fieldProto),
			Type:     strings.ToLower(fieldType),
			Repeated: field.IsRepeated(),
			Map:      field.IsMap(),
		}
		if field.GetMessageType() != nil && !field.IsMap() {
			grpcField.MessageType = field.GetMessageType().GetFullyQualifiedName()
		}
		if field.IsMap() {
			grpcField.MessageType = "map"
		}
		if field.GetType() == descriptorpb.FieldDescriptorProto_TYPE_ENUM && field.GetEnumType() != nil {
			values := field.GetEnumType().GetValues()
			grpcField.EnumValues = make([]string, 0, len(values))
			for _, value := range values {
				grpcField.EnumValues = append(grpcField.EnumValues, value.GetName())
			}
		}
		out = append(out, grpcField)
	}
	return out
}

func describeMessageTypes(root *desc.MessageDescriptor) map[string]GrpcMessageType {
	if root == nil {
		return nil
	}

	messageTypes := make(map[string]GrpcMessageType)
	visited := make(map[string]struct{})
	var visit func(*desc.MessageDescriptor)
	visit = func(message *desc.MessageDescriptor) {
		if message == nil {
			return
		}
		name := message.GetFullyQualifiedName()
		if _, ok := visited[name]; ok {
			return
		}
		visited[name] = struct{}{}
		messageTypes[name] = GrpcMessageType{Fields: describeFields(message)}

		for _, field := range message.GetFields() {
			if field.IsMap() {
				continue
			}
			visit(field.GetMessageType())
		}
	}

	visit(root)
	return messageTypes
}

func jsonFieldName(field *descriptorpb.FieldDescriptorProto) string {
	if field.GetJsonName() != "" {
		return field.GetJsonName()
	}
	parts := strings.Split(field.GetName(), "_")
	for index := 1; index < len(parts); index++ {
		if parts[index] == "" {
			continue
		}
		parts[index] = strings.ToUpper(parts[index][:1]) + parts[index][1:]
	}
	return strings.Join(parts, "")
}

func marshalDynamicResponse(message proto.Message) (string, error) {
	if dynamicMessage, ok := message.(*dynamic.Message); ok {
		bytes, err := dynamicMessage.MarshalJSONIndent()
		return string(bytes), err
	}
	bytes, err := proto.MarshalTextString(message), error(nil)
	return bytes, err
}

func flattenMetadata(header metadata.MD, trailer metadata.MD) map[string]string {
	out := map[string]string{}
	for key, values := range header {
		out[key] = strings.Join(values, ", ")
	}
	for key, values := range trailer {
		out[key] = strings.Join(values, ", ")
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func invocationError(code string, message string, start time.Time) InvokeResponse {
	return InvokeResponse{
		OK:            false,
		StatusCode:    code,
		StatusMessage: message,
		DurationMs:    time.Since(start).Milliseconds(),
		Error:         message,
	}
}

func grpcCodeName(code codes.Code) string {
	name := code.String()
	var builder strings.Builder
	for index, char := range name {
		if index > 0 && char >= 'A' && char <= 'Z' {
			builder.WriteByte('_')
		}
		builder.WriteRune(char)
	}
	return strings.ToUpper(builder.String())
}

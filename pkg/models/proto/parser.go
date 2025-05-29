package proto

import (
	"encoding/json"
	"fmt"
	"io/ioutil"
	"os"
	"os/exec"
	"path/filepath"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/descriptorpb"
)

// Parser handles the parsing of proto files
type Parser struct {
	importPaths []string // List of paths to search for imports
}

// NewParser creates a new Parser instance
func NewParser(importPaths []string) *Parser {
	return &Parser{
		importPaths: importPaths,
	}
}

// ParseFile parses a proto file and returns a ProtoDefinition
func (p *Parser) ParseFile(filePath string) (*ProtoDefinition, error) {
	visited := map[string]bool{}
	return p.parseFileWithVisited(filePath, visited)
}

// parseFileWithVisited parses a proto file and tracks visited files for circular import detection
func (p *Parser) parseFileWithVisited(filePath string, visited map[string]bool) (*ProtoDefinition, error) {
	dependencyGraph := make(map[string][]string)
	return p.parseFileWithVisitedGraph(filePath, visited, dependencyGraph)
}

func (p *Parser) parseFileWithVisitedGraph(filePath string, visited map[string]bool, dependencyGraph map[string][]string) (*ProtoDefinition, error) {
	// Track the import chain for better error messages
	importChain := make([]string, 0, len(visited)+1)
	for k := range visited {
		importChain = append(importChain, k)
	}
	importChain = append(importChain, filePath)

	if visited[filePath] {
		return nil, fmt.Errorf("circular import detected: %s\nFull import chain: %v", filePath, importChain)
	}
	visited[filePath] = true

	// Read the file content
	content, err := ioutil.ReadFile(filePath)
	if err != nil {
		return nil, fmt.Errorf("failed to read proto file %s: %w", filePath, err)
	}

	// Create a new ProtoDefinition
	pd := NewProtoDefinition(filePath, string(content))

	// Parse the proto file
	fileDesc, err := p.parseProtoFile(filePath, content)
	if err != nil {
		return nil, fmt.Errorf("failed to parse proto file %s: %w", filePath, err)
	}

	// Extract imports
	imports := fileDesc.Imports()
	var importList []string
	for i := 0; i < imports.Len(); i++ {
		imp := imports.Get(i)
		importList = append(importList, imp.Path())
	}
	dependencyGraph[filePath] = importList
	pd.Imports = importList
	pd.DependencyGraph = dependencyGraph

	// Extract enums
	enums := fileDesc.Enums()
	for i := 0; i < enums.Len(); i++ {
		enum := enums.Get(i)
		enumType := EnumType{
			Name:        string(enum.Name()),
			Description: p.extractComments(enum.ParentFile(), int32(enum.Index())),
		}
		for j := 0; j < enum.Values().Len(); j++ {
			val := enum.Values().Get(j)
			enumType.Values = append(enumType.Values, EnumValue{
				Name:        string(val.Name()),
				Number:      int32(val.Number()),
				Description: p.extractComments(val.ParentFile(), int32(val.Index())),
			})
		}
		pd.Enums = append(pd.Enums, enumType)
	}

	// Extract file options
	if fileDesc.Options() != nil {
		if bytes, err := json.Marshal(fileDesc.Options()); err == nil {
			pd.FileOptions = string(bytes)
		} else {
			pd.FileOptions = "<error marshaling file options>"
		}
	}

	// Extract services
	services := fileDesc.Services()
	for i := 0; i < services.Len(); i++ {
		svc := services.Get(i)
		service := Service{
			Name:        string(svc.Name()),
			Description: p.extractComments(svc.ParentFile(), int32(svc.Index())),
		}

		// Extract methods
		methods := svc.Methods()
		for j := 0; j < methods.Len(); j++ {
			method := methods.Get(j)
			methodDesc := Method{
				Name:            string(method.Name()),
				Description:     p.extractComments(method.ParentFile(), int32(method.Index())),
				ClientStreaming: method.IsStreamingClient(),
				ServerStreaming: method.IsStreamingServer(),
			}

			// Extract input type
			methodDesc.InputType = p.extractMessageType(method.Input())

			// Extract output type
			methodDesc.OutputType = p.extractMessageType(method.Output())

			service.Methods = append(service.Methods, methodDesc)
		}

		pd.AddService(service)
	}

	return pd, nil
}

// parseProtoFile parses a proto file and returns its FileDescriptor
func (p *Parser) parseProtoFile(filePath string, content []byte) (protoreflect.FileDescriptor, error) {
	// Create a temporary directory for protoc output
	tmpDir, err := ioutil.TempDir("", "protoc")
	if err != nil {
		return nil, fmt.Errorf("failed to create temp dir: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	// Get the base directory of the proto file
	baseDir := filepath.Dir(filePath)

	// Copy all .proto files from all import paths into tmpDir
	for _, importPath := range p.importPaths {
		err = filepath.Walk(importPath, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return err
			}
			if !info.IsDir() && filepath.Ext(path) == ".proto" {
				// Calculate relative path from import path
				relPath, err := filepath.Rel(importPath, path)
				if err != nil {
					return err
				}
				// Create the same directory structure in tmpDir
				dst := filepath.Join(tmpDir, relPath)
				dstDir := filepath.Dir(dst)
				if err := os.MkdirAll(dstDir, 0755); err != nil {
					return err
				}
				// Copy the file
				data, err := ioutil.ReadFile(path)
				if err != nil {
					return err
				}
				if err := ioutil.WriteFile(dst, data, 0644); err != nil {
					return err
				}
			}
			return nil
		})
		if err != nil {
			return nil, fmt.Errorf("failed to copy proto files from %s: %w", importPath, err)
		}
	}

	// Write the main proto file content (overwrites if already copied)
	relPath, err := filepath.Rel(baseDir, filePath)
	if err != nil {
		return nil, fmt.Errorf("failed to get relative path: %w", err)
	}
	tmpFile := filepath.Join(tmpDir, relPath)
	if err := ioutil.WriteFile(tmpFile, content, 0644); err != nil {
		return nil, fmt.Errorf("failed to write temp file: %w", err)
	}

	// Prepare protoc command
	args := []string{
		"--proto_path=" + baseDir, // Add the base directory as the first import path
		"--proto_path=" + tmpDir,  // Add the temp directory
		"--descriptor_set_out=" + filepath.Join(tmpDir, "descriptor.pb"),
		"--include_imports",
	}

	// Add all import paths
	for _, path := range p.importPaths {
		args = append(args, "--proto_path="+path)
	}

	// Add the main proto file
	args = append(args, tmpFile)

	fmt.Printf("[DEBUG] Running protoc with args: %v\n", args)

	// Run protoc and surface errors clearly
	cmd := exec.Command("protoc", args...)
	// Set working directory to the base directory so all imports are available
	cmd.Dir = baseDir
	if output, err := cmd.CombinedOutput(); err != nil {
		return nil, fmt.Errorf("protoc failed (output: %s): %w", string(output), err)
	}

	// Read the generated descriptor set
	descriptorBytes, err := ioutil.ReadFile(filepath.Join(tmpDir, "descriptor.pb"))
	if err != nil {
		return nil, fmt.Errorf("failed to read descriptor set: %w", err)
	}

	// Parse the descriptor set
	descriptorSet := &descriptorpb.FileDescriptorSet{}
	if err := proto.Unmarshal(descriptorBytes, descriptorSet); err != nil {
		return nil, fmt.Errorf("failed to unmarshal descriptor set: %w", err)
	}

	// Create a file registry from the descriptor set
	registry, err := protodesc.NewFiles(descriptorSet)
	if err != nil {
		return nil, fmt.Errorf("failed to create file registry: %w", err)
	}

	// Find the target file in the registry (use relative path)
	fileDesc, err := registry.FindFileByPath(relPath)
	if err != nil {
		return nil, fmt.Errorf("failed to find file in registry: %w.\nIf this is an import issue, check your import paths.", err)
	}

	return fileDesc, nil
}

// resolveImport attempts to find and parse an imported proto file
func (p *Parser) resolveImport(importPath string) (*descriptorpb.FileDescriptorProto, error) {
	// Try to find the import in the import paths
	for _, path := range p.importPaths {
		fullPath := filepath.Join(path, importPath)
		if _, err := os.Stat(fullPath); err == nil {
			content, err := ioutil.ReadFile(fullPath)
			if err != nil {
				continue
			}

			fd := &descriptorpb.FileDescriptorProto{}
			if err := proto.Unmarshal(content, fd); err != nil {
				continue
			}

			return fd, nil
		}
	}

	// If not found in import paths, try to use well-known types from the protobuf package
	if desc, err := protoregistry.GlobalFiles.FindFileByPath(importPath); err == nil {
		return protodesc.ToFileDescriptorProto(desc), nil
	}

	// If still not found, try to use the built-in well-known types
	switch importPath {
	case "google/protobuf/timestamp.proto":
		// Use the built-in Timestamp type
		return &descriptorpb.FileDescriptorProto{
			Name:    proto.String("google/protobuf/timestamp.proto"),
			Package: proto.String("google.protobuf"),
			MessageType: []*descriptorpb.DescriptorProto{
				{
					Name: proto.String("Timestamp"),
					Field: []*descriptorpb.FieldDescriptorProto{
						{
							Name:   proto.String("seconds"),
							Number: proto.Int32(1),
							Type:   descriptorpb.FieldDescriptorProto_TYPE_INT64.Enum(),
						},
						{
							Name:   proto.String("nanos"),
							Number: proto.Int32(2),
							Type:   descriptorpb.FieldDescriptorProto_TYPE_INT32.Enum(),
						},
					},
				},
			},
		}, nil
	}

	return nil, fmt.Errorf("import %s not found", importPath)
}

// extractMessageType extracts message type information from a MessageDescriptor
func (p *Parser) extractMessageType(msg protoreflect.MessageDescriptor) MessageType {
	mt := MessageType{
		Name:        string(msg.Name()),
		Description: p.extractComments(msg.ParentFile(), int32(msg.Index())),
	}

	fields := msg.Fields()
	for i := 0; i < fields.Len(); i++ {
		field := fields.Get(i)
		mf := MessageField{
			Name:        string(field.Name()),
			Number:      int32(field.Number()),
			Type:        p.getFieldTypeName(field),
			IsRepeated:  field.Cardinality() == protoreflect.Repeated,
			IsRequired:  field.Cardinality() == protoreflect.Required,
			Description: p.extractComments(field.ParentFile(), int32(field.Index())),
			Options: FieldOption{
				JSONName: string(field.JSONName()),
			},
		}
		mt.Fields = append(mt.Fields, mf)
	}

	return mt
}

// getFieldTypeName returns a string representation of the field type
func (p *Parser) getFieldTypeName(field protoreflect.FieldDescriptor) string {
	if field.IsMap() {
		keyType := p.getFieldTypeName(field.MapKey())
		valueType := p.getFieldTypeName(field.MapValue())
		return fmt.Sprintf("map<%s, %s>", keyType, valueType)
	}

	switch field.Kind() {
	case protoreflect.MessageKind, protoreflect.GroupKind:
		return string(field.Message().Name())
	case protoreflect.EnumKind:
		return string(field.Enum().Name())
	default:
		return field.Kind().String()
	}
}

// extractComments extracts comments from the source location
func (p *Parser) extractComments(file protoreflect.FileDescriptor, index int32) string {
	// This is a placeholder. In a real implementation, we would:
	// 1. Get the source code info from the FileDescriptorProto
	// 2. Find the location for the given path
	// 3. Extract and format the comments
	return ""
}

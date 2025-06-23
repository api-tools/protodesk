package services

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/google/uuid"
	pbproto "google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/descriptorpb"

	"protodesk/pkg/models/proto"
)

// ProtoParser handles parsing of proto files
type ProtoParser struct {
	store ServerProfileStore
}

// NewProtoParser creates a new ProtoParser
func NewProtoParser(store ServerProfileStore) *ProtoParser {
	return &ProtoParser{
		store: store,
	}
}

// ScanAndParseProtoPath scans a directory for proto files and parses them
func (p *ProtoParser) ScanAndParseProtoPath(ctx context.Context, serverProfileId string, protoPathId string, path string) error {
	// Find all proto files
	var protoFiles []string
	err := filepath.Walk(path, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		// Skip node_modules directory
		if info.IsDir() && info.Name() == "node_modules" {
			return filepath.SkipDir
		}
		if !info.IsDir() && strings.HasSuffix(info.Name(), ".proto") {
			protoFiles = append(protoFiles, path)
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("failed to walk directory: %w", err)
	}

	// Build import paths
	var importPaths []string
	// Find the root proto directory by walking up until we find a directory containing 'proto'
	rootProtoDir := path
	for {
		parent := filepath.Dir(rootProtoDir)
		if parent == rootProtoDir {
			break // Reached root directory
		}
		if filepath.Base(parent) == "proto" {
			rootProtoDir = parent
			break
		}
		rootProtoDir = parent
	}
	importPaths = append(importPaths, rootProtoDir)
	// Add the base directory and the proto path itself
	baseDir := filepath.Dir(path)
	importPaths = append(importPaths, baseDir)
	importPaths = append(importPaths, path)

	// Add include paths for well-known types from the database (no hardcoded paths)
	wellKnownTypes, err := p.store.ListWellKnownTypes(ctx)
	if err == nil {
		seen := map[string]struct{}{}
		for _, p := range importPaths {
			seen[p] = struct{}{}
		}
		for _, wkt := range wellKnownTypes {
			if wkt.IncludePath != "" {
				if _, ok := seen[wkt.IncludePath]; !ok {
					importPaths = append(importPaths, wkt.IncludePath)
					seen[wkt.IncludePath] = struct{}{}
				}
			}
		}
	}

	// Build a map from import path (as written in proto files) to absolute file path
	importPathToAbs := make(map[string]string)
	for _, f := range protoFiles {
		abs, err := filepath.Abs(f)
		if err != nil {
			continue
		}
		// Try to get the import path relative to the root proto dir
		rel, err := filepath.Rel(rootProtoDir, abs)
		if err != nil {
			rel = filepath.Base(abs) // fallback to just the filename
		}
		importPathToAbs[rel] = abs
		importPathToAbs[filepath.ToSlash(rel)] = abs // ensure forward slashes for proto imports
		importPathToAbs[filepath.Base(abs)] = abs    // fallback for just the filename
	}

	fmt.Printf("[DEBUG] Import path to abs map:\n")
	for k, v := range importPathToAbs {
		fmt.Printf("  %s -> %s\n", k, v)
	}

	// Build a set of all found proto files (absolute paths)
	foundFiles := make(map[string]struct{})
	for _, f := range protoFiles {
		abs, err := filepath.Abs(f)
		if err == nil {
			foundFiles[abs] = struct{}{}
		}
	}

	fmt.Printf("[DEBUG] Found proto files (absolute):\n")
	for abs := range foundFiles {
		fmt.Printf("  %s\n", abs)
	}

	successfullyParsed := 0
	// Parse each proto file
	for _, file := range protoFiles {
		// Normalize file path to absolute path
		// absFile, err := filepath.Abs(file)
		// if err != nil {
		// 	absFile = file // fallback to original if error
		// }
		// Create a temporary file for the descriptor set
		tmpFile, err := os.CreateTemp("", "protoc-*.desc")
		if err != nil {
			continue
		}
		tmpFile.Close()
		defer os.Remove(tmpFile.Name())

		// Build protoc command arguments
		args := []string{
			"--descriptor_set_out=" + tmpFile.Name(),
			"--include_imports",
		}
		for _, importPath := range importPaths {
			args = append(args, "-I"+importPath)
		}
		args = append(args, file)

		// Run protoc command
		cmd := exec.CommandContext(ctx, "protoc", args...)
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		err = cmd.Run()
		if err != nil {
			continue
		}

		// Read the descriptor set from the temporary file
		output, err := os.ReadFile(tmpFile.Name())
		if err != nil {
			continue
		}

		// Parse descriptor set
		descriptorSet := &descriptorpb.FileDescriptorSet{}
		if err := pbproto.Unmarshal(output, descriptorSet); err != nil {
			continue
		}

		// Process each file descriptor
		for _, fileDesc := range descriptorSet.File {
			realPath, ok := importPathToAbs[fileDesc.GetName()]
			if !ok {
				fmt.Printf("[DEBUG] Skipping proto definition for %s (not found in import map)\n", fileDesc.GetName())
				continue
			}
			content, err := os.ReadFile(realPath)
			if err != nil {
				fmt.Printf("[DEBUG] Failed to read proto file %s: %v\n", realPath, err)
				continue
			}

			// Get the actual file path from the descriptor
			filePath := fileDesc.GetName()
			if strings.HasPrefix(filePath, "google/protobuf/") {
				// If it's a google/protobuf file, use the original file path
				filePath = file
			}

			// Create proto definition
			def := &proto.ProtoDefinition{
				ID:              uuid.New().String(),
				FilePath:        realPath,
				Content:         string(content),
				Imports:         fileDesc.GetDependency(),
				Services:        make([]proto.Service, 0),
				Enums:           make([]proto.EnumType, 0),
				CreatedAt:       time.Now(),
				UpdatedAt:       time.Now(),
				ServerProfileID: serverProfileId,
				ProtoPathID:     protoPathId,
			}

			// Extract services and methods
			for _, service := range fileDesc.GetService() {
				// Get the full service name including package
				serviceName := service.GetName()
				if fileDesc.GetPackage() != "" {
					serviceName = fileDesc.GetPackage() + "." + serviceName
				}

				svc := proto.Service{
					Name:    serviceName,
					Methods: make([]proto.Method, 0),
				}

				for _, method := range service.GetMethod() {
					// Find input message type
					var inputType proto.MessageType
					inputTypeName := method.GetInputType()
					// Remove the leading dot if present
					if strings.HasPrefix(inputTypeName, ".") {
						inputTypeName = inputTypeName[1:]
					}
					// Find the message in the descriptor set
					for _, msg := range descriptorSet.File {
						for _, message := range msg.GetMessageType() {
							fullMessageName := msg.GetPackage()
							if fullMessageName != "" {
								fullMessageName += "."
							}
							fullMessageName += message.GetName()
							if fullMessageName == inputTypeName {
								inputType = proto.MessageType{
									Name:   inputTypeName,
									Fields: make([]proto.MessageField, 0),
								}
								for _, field := range message.GetField() {
									fieldType := protoTypeToString(field.GetType())
									if field.GetType() == descriptorpb.FieldDescriptorProto_TYPE_MESSAGE {
										fieldType = field.GetTypeName()
										if strings.HasPrefix(fieldType, ".") {
											fieldType = fieldType[1:]
										}
										// Handle Google well-known types
										if strings.HasPrefix(fieldType, "google.protobuf.") {
											// For well-known types, we need to keep the full type name
											fieldType = fieldType
											// Add the well-known type to imports if not already present
											wellKnownType := strings.TrimPrefix(fieldType, "google.protobuf.")
											wellKnownProto := fmt.Sprintf("google/protobuf/%s.proto", strings.ToLower(wellKnownType))
											found := false
											for _, imp := range def.Imports {
												if imp == wellKnownProto {
													found = true
													break
												}
											}
											if !found {
												def.Imports = append(def.Imports, wellKnownProto)
											}
										}
									} else if field.GetType() == descriptorpb.FieldDescriptorProto_TYPE_ENUM {
										fieldType = field.GetTypeName()
										if strings.HasPrefix(fieldType, ".") {
											fieldType = fieldType[1:]
										}
									}

									msgField := proto.MessageField{
										Name:       field.GetName(),
										Number:     int32(field.GetNumber()),
										Type:       fieldType,
										IsRepeated: field.GetLabel() == descriptorpb.FieldDescriptorProto_LABEL_REPEATED,
										IsRequired: field.GetLabel() == descriptorpb.FieldDescriptorProto_LABEL_REQUIRED,
										Options: proto.FieldOption{
											JSONName: field.GetJsonName(),
										},
									}
									inputType.Fields = append(inputType.Fields, msgField)
								}
								break
							}
						}
					}

					// Find output message type
					var outputType proto.MessageType
					outputTypeName := method.GetOutputType()
					// Remove the leading dot if present
					if strings.HasPrefix(outputTypeName, ".") {
						outputTypeName = outputTypeName[1:]
					}
					// Find the message in the descriptor set
					for _, msg := range descriptorSet.File {
						for _, message := range msg.GetMessageType() {
							fullMessageName := msg.GetPackage()
							if fullMessageName != "" {
								fullMessageName += "."
							}
							fullMessageName += message.GetName()
							if fullMessageName == outputTypeName {
								outputType = proto.MessageType{
									Name:   outputTypeName,
									Fields: make([]proto.MessageField, 0),
								}
								for _, field := range message.GetField() {
									fieldType := protoTypeToString(field.GetType())
									if field.GetType() == descriptorpb.FieldDescriptorProto_TYPE_MESSAGE {
										fieldType = field.GetTypeName()
										if strings.HasPrefix(fieldType, ".") {
											fieldType = fieldType[1:]
										}
										// Handle Google well-known types
										if strings.HasPrefix(fieldType, "google.protobuf.") {
											// For well-known types, we need to keep the full type name
											fieldType = fieldType
											// Add the well-known type to imports if not already present
											wellKnownType := strings.TrimPrefix(fieldType, "google.protobuf.")
											wellKnownProto := fmt.Sprintf("google/protobuf/%s.proto", strings.ToLower(wellKnownType))
											found := false
											for _, imp := range def.Imports {
												if imp == wellKnownProto {
													found = true
													break
												}
											}
											if !found {
												def.Imports = append(def.Imports, wellKnownProto)
											}
										}
									} else if field.GetType() == descriptorpb.FieldDescriptorProto_TYPE_ENUM {
										fieldType = field.GetTypeName()
										if strings.HasPrefix(fieldType, ".") {
											fieldType = fieldType[1:]
										}
									}

									msgField := proto.MessageField{
										Name:       field.GetName(),
										Number:     int32(field.GetNumber()),
										Type:       fieldType,
										IsRepeated: field.GetLabel() == descriptorpb.FieldDescriptorProto_LABEL_REPEATED,
										IsRequired: field.GetLabel() == descriptorpb.FieldDescriptorProto_LABEL_REQUIRED,
										Options: proto.FieldOption{
											JSONName: field.GetJsonName(),
										},
									}
									outputType.Fields = append(outputType.Fields, msgField)
								}
								break
							}
						}
					}

					svc.Methods = append(svc.Methods, proto.Method{
						Name:            method.GetName(),
						InputType:       inputType,
						OutputType:      outputType,
						ClientStreaming: method.GetClientStreaming(),
						ServerStreaming: method.GetServerStreaming(),
					})
				}

				def.Services = append(def.Services, svc)
			}

			// Extract enums
			for _, enum := range fileDesc.GetEnumType() {
				enumDef := proto.EnumType{
					Name:   enum.GetName(),
					Values: make([]proto.EnumValue, 0),
				}

				for _, value := range enum.GetValue() {
					enumDef.Values = append(enumDef.Values, proto.EnumValue{
						Name:   value.GetName(),
						Number: int32(value.GetNumber()),
					})
				}

				def.Enums = append(def.Enums, enumDef)
			}

			// Extract messages
			for _, message := range fileDesc.GetMessageType() {
				msgType := proto.MessageType{
					Name:   message.GetName(),
					Fields: make([]proto.MessageField, 0),
				}

				for _, field := range message.GetField() {
					fieldType := protoTypeToString(field.GetType())
					if field.GetType() == descriptorpb.FieldDescriptorProto_TYPE_MESSAGE {
						fieldType = field.GetTypeName()
						if strings.HasPrefix(fieldType, ".") {
							fieldType = fieldType[1:]
						}
						// Handle Google well-known types
						if strings.HasPrefix(fieldType, "google.protobuf.") {
							// For well-known types, we need to keep the full type name
							fieldType = fieldType
							// Add the well-known type to imports if not already present
							wellKnownType := strings.TrimPrefix(fieldType, "google.protobuf.")
							wellKnownProto := fmt.Sprintf("google/protobuf/%s.proto", strings.ToLower(wellKnownType))
							found := false
							for _, imp := range def.Imports {
								if imp == wellKnownProto {
									found = true
									break
								}
							}
							if !found {
								def.Imports = append(def.Imports, wellKnownProto)
							}
						}
					} else if field.GetType() == descriptorpb.FieldDescriptorProto_TYPE_ENUM {
						fieldType = field.GetTypeName()
						if strings.HasPrefix(fieldType, ".") {
							fieldType = fieldType[1:]
						}
					}

					msgField := proto.MessageField{
						Name:       field.GetName(),
						Number:     int32(field.GetNumber()),
						Type:       fieldType,
						IsRepeated: field.GetLabel() == descriptorpb.FieldDescriptorProto_LABEL_REPEATED,
						IsRequired: field.GetLabel() == descriptorpb.FieldDescriptorProto_LABEL_REQUIRED,
						Options: proto.FieldOption{
							JSONName: field.GetJsonName(),
						},
					}

					msgType.Fields = append(msgType.Fields, msgField)
				}

				def.Messages = append(def.Messages, msgType)
			}

			// Extract file options
			if opts := fileDesc.GetOptions(); opts != nil {
				fileOptionsMap := make(map[string]interface{})
				if opts.JavaPackage != nil {
					fileOptionsMap["java_package"] = opts.GetJavaPackage()
				}
				if opts.GoPackage != nil {
					fileOptionsMap["go_package"] = opts.GetGoPackage()
				}
				if opts.CsharpNamespace != nil {
					fileOptionsMap["csharp_namespace"] = opts.GetCsharpNamespace()
				}
				if len(fileOptionsMap) > 0 {
					if b, err := json.Marshal(fileOptionsMap); err == nil {
						def.FileOptions = string(b)
					}
				}
			}

			// Check if proto definition already exists
			existingDefs, err := p.store.ListProtoDefinitionsByProfile(ctx, serverProfileId)
			if err != nil {
				fmt.Printf("[DEBUG] Failed to list proto definitions for profile %s: %v\n", serverProfileId, err)
				continue
			}

			var existingDef *proto.ProtoDefinition
			for _, d := range existingDefs {
				normalizedExistingPath, _ := filepath.Abs(d.FilePath)
				normalizedNewPath, _ := filepath.Abs(realPath)
				if normalizedExistingPath == normalizedNewPath {
					existingDef = d
					break
				}
			}

			if existingDef != nil {
				def.ID = existingDef.ID
				def.CreatedAt = existingDef.CreatedAt
				// Delete any duplicate definitions with the same file path
				for _, d := range existingDefs {
					if d.ID != existingDef.ID {
						normalizedExistingPath, _ := filepath.Abs(d.FilePath)
						normalizedNewPath, _ := filepath.Abs(realPath)
						if normalizedExistingPath == normalizedNewPath {
							err = p.store.DeleteProtoDefinition(ctx, d.ID)
							if err != nil {
								fmt.Printf("[DEBUG] Failed to delete duplicate proto definition %s: %v\n", d.ID, err)
								continue
							}
						}
					}
				}
				err = p.store.UpdateProtoDefinition(ctx, def)
				if err != nil {
					fmt.Printf("[DEBUG] Failed to update proto definition for %s: %v\n", realPath, err)
					continue
				}
				fmt.Printf("[DEBUG] Updated proto definition: %s\n", realPath)
			} else {
				err = p.store.CreateProtoDefinition(ctx, def)
				if err != nil {
					fmt.Printf("[DEBUG] Failed to create proto definition for %s: %v\n", realPath, err)
					continue
				}
				fmt.Printf("[DEBUG] Created proto definition: %s\n", realPath)
			}
			successfullyParsed++
		}
	}

	return nil
}

// getWellKnownTypeImports returns a list of well-known type imports that should be included
func getWellKnownTypeImports() []string {
	return []string{
		"google/protobuf/timestamp.proto",
		"google/protobuf/empty.proto",
		"google/protobuf/any.proto",
		"google/protobuf/struct.proto",
		"google/protobuf/wrappers.proto",
		"google/protobuf/duration.proto",
	}
}

// ParseProtoFiles parses proto files and returns their definitions
func (p *ProtoParser) ParseProtoFiles(ctx context.Context, protoFiles []string, importPaths []string) ([]*proto.ProtoDefinition, error) {
	// Add well-known type imports to the import paths
	wellKnownTypesPath := os.Getenv("PROTOBUF_WELL_KNOWN_TYPES_PATH")
	if wellKnownTypesPath != "" {
		importPaths = append(importPaths, wellKnownTypesPath)
	}

	var definitions []*proto.ProtoDefinition
	for _, file := range protoFiles {
		content, err := os.ReadFile(file)
		if err != nil {
			return nil, fmt.Errorf("failed to read proto file %s: %w", file, err)
		}

		def := &proto.ProtoDefinition{
			ID:              uuid.New().String(),
			FilePath:        file,
			Content:         string(content),
			Imports:         getWellKnownTypeImports(), // Add well-known type imports by default
			Services:        make([]proto.Service, 0),
			Messages:        make([]proto.MessageType, 0),
			CreatedAt:       time.Now(),
			UpdatedAt:       time.Now(),
			ServerProfileID: "", // This will be set by the caller if needed
		}

		// ... rest of the parsing logic ...
		definitions = append(definitions, def)
	}

	return definitions, nil
}

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
	fmt.Printf("[DEBUG] Scanning proto path: %s\n", path)

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
			fmt.Printf("[DEBUG] Found proto file: %s\n", path)
			protoFiles = append(protoFiles, path)
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("failed to walk directory: %w", err)
	}

	fmt.Printf("[DEBUG] Total proto files to parse: %d\n", len(protoFiles))

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

	fmt.Printf("[DEBUG] Using import paths: %v\n", importPaths)

	successfullyParsed := 0
	// Parse each proto file
	for _, file := range protoFiles {
		fmt.Printf("[DEBUG] Parsing file: %s\n", file)

		// Create a temporary file for the descriptor set
		tmpFile, err := os.CreateTemp("", "protoc-*.desc")
		if err != nil {
			fmt.Printf("[DEBUG] Failed to create temporary file: %v\n", err)
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

		fmt.Printf("[DEBUG] Running protoc with args: %v\n", args)

		// Run protoc command
		cmd := exec.CommandContext(ctx, "protoc", args...)
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		err = cmd.Run()
		if err != nil {
			fmt.Printf("[DEBUG] Failed to run protoc: %v\n", err)
			fmt.Printf("[DEBUG] protoc stderr output: %s\n", stderr.String())
			continue
		}

		// Read the descriptor set from the temporary file
		output, err := os.ReadFile(tmpFile.Name())
		if err != nil {
			fmt.Printf("[DEBUG] Failed to read descriptor set file: %v\n", err)
			continue
		}

		fmt.Printf("[DEBUG] Read %d bytes from descriptor set file\n", len(output))
		fmt.Printf("[DEBUG] protoc stderr output: %s\n", stderr.String())

		// Parse descriptor set
		descriptorSet := &descriptorpb.FileDescriptorSet{}
		if err := pbproto.Unmarshal(output, descriptorSet); err != nil {
			fmt.Printf("[DEBUG] Failed to unmarshal descriptor set: %v\n", err)
			continue
		}

		fmt.Printf("[DEBUG] Successfully parsed descriptor set with %d files\n", len(descriptorSet.File))

		// Process each file descriptor
		for _, fileDesc := range descriptorSet.File {
			fmt.Printf("[DEBUG] Processing file descriptor: %s\n", fileDesc.GetName())

			// Read the original proto file content
			content, err := os.ReadFile(file)
			if err != nil {
				fmt.Printf("[DEBUG] Failed to read proto file: %v\n", err)
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
				FilePath:        filePath,
				Content:         string(content),
				Imports:         fileDesc.GetDependency(),
				Services:        make([]proto.Service, 0),
				Enums:           make([]proto.EnumType, 0),
				CreatedAt:       time.Now(),
				UpdatedAt:       time.Now(),
				ServerProfileID: serverProfileId,
				ProtoPathID:     protoPathId,
			}

			fmt.Printf("[DEBUG] Created proto definition object - ID: %s, FilePath: %s\n", def.ID, def.FilePath)

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
							if msg.GetPackage()+"."+message.GetName() == inputTypeName {
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
							if msg.GetPackage()+"."+message.GetName() == outputTypeName {
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

			fmt.Printf("[DEBUG] Found %d services\n", len(def.Services))
			if len(def.Services) > 0 {
				fmt.Printf("[DEBUG] First service has %d methods\n", len(def.Services[0].Methods))
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

			fmt.Printf("[DEBUG] Found %d enums\n", len(def.Enums))

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
					} else if field.GetType() == descriptorpb.FieldDescriptorProto_TYPE_ENUM {
						fieldType = field.GetTypeName()
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

			fmt.Printf("[DEBUG] Found %d messages\n", len(def.Messages))

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
				fmt.Printf("[DEBUG] Failed to list proto definitions: %v\n", err)
				continue
			}

			var existingDef *proto.ProtoDefinition
			for _, d := range existingDefs {
				normalizedExistingPath, _ := filepath.Abs(d.FilePath)
				normalizedNewPath, _ := filepath.Abs(def.FilePath)
				fmt.Printf("[DEBUG] Comparing file paths - existing: %s, new: %s\n", normalizedExistingPath, normalizedNewPath)
				if normalizedExistingPath == normalizedNewPath {
					existingDef = d
					break
				}
			}

			if existingDef != nil {
				fmt.Printf("[DEBUG] Found existing definition, updating...\n")
				def.ID = existingDef.ID
				def.CreatedAt = existingDef.CreatedAt
				err = p.store.UpdateProtoDefinition(ctx, def)
				if err != nil {
					fmt.Printf("[DEBUG] Failed to update proto definition: %v\n", err)
					continue
				}
				fmt.Printf("[DEBUG] Successfully updated proto definition for %s\n", def.FilePath)
			} else {
				fmt.Printf("[DEBUG] Creating new proto definition...\n")
				err = p.store.CreateProtoDefinition(ctx, def)
				if err != nil {
					fmt.Printf("[DEBUG] Failed to create proto definition: %v\n", err)
					continue
				}
				fmt.Printf("[DEBUG] Successfully created proto definition for %s\n", def.FilePath)
			}
			successfullyParsed++
		}
	}

	fmt.Printf("[DEBUG] Successfully parsed and saved %d proto definitions out of %d files\n", successfullyParsed, len(protoFiles))
	return nil
}

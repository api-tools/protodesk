package services

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/jhump/protoreflect/desc"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/descriptorpb"
)

// DefaultProtoParser is the default implementation of ProtoParser
type DefaultProtoParser struct {
	parsedFiles map[string]*desc.FileDescriptor
	services    map[string]*desc.ServiceDescriptor
	methods     map[string]*desc.MethodDescriptor
	messages    map[string]*desc.MessageDescriptor
	enums       map[string]*desc.EnumDescriptor
}

// NewDefaultProtoParser creates a new DefaultProtoParser
func NewDefaultProtoParser() *DefaultProtoParser {
	return &DefaultProtoParser{
		parsedFiles: make(map[string]*desc.FileDescriptor),
		services:    make(map[string]*desc.ServiceDescriptor),
		methods:     make(map[string]*desc.MethodDescriptor),
		messages:    make(map[string]*desc.MessageDescriptor),
		enums:       make(map[string]*desc.EnumDescriptor),
	}
}

// copyFile copies a file from src to dst
func copyFile(src, dst string) error {
	sourceFile, err := os.Open(src)
	if err != nil {
		return err
	}
	defer sourceFile.Close()

	destFile, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer destFile.Close()

	_, err = io.Copy(destFile, sourceFile)
	return err
}

// ScanAndParseProtoPath scans a directory for .proto files and parses them
func (p *DefaultProtoParser) ScanAndParseProtoPath(path string) error {
	fmt.Printf("[DEBUG] Scanning proto path: %s\n", path)

	// Create a map to store unique import paths
	importPaths := make(map[string]bool)
	importPaths[path] = true

	// First pass: collect all directories that contain .proto files
	err := filepath.Walk(path, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			// Check if this directory contains any .proto files
			entries, err := os.ReadDir(path)
			if err != nil {
				return err
			}
			for _, entry := range entries {
				if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".proto") {
					importPaths[path] = true
					fmt.Printf("[DEBUG] Added import path: %s\n", path)
					break
				}
			}
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("failed to scan directory: %w", err)
	}

	// Convert map to sorted slice of paths (most specific first)
	var paths []string
	for p := range importPaths {
		paths = append(paths, p)
	}
	sort.Slice(paths, func(i, j int) bool {
		// Sort by path length in descending order (most specific first)
		return len(paths[i]) > len(paths[j])
	})

	// Second pass: collect all .proto files
	var protoFiles []string
	err = filepath.Walk(path, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() && strings.HasSuffix(info.Name(), ".proto") {
			protoFiles = append(protoFiles, path)
			fmt.Printf("[DEBUG] Found proto file: %s\n", path)
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("failed to collect proto files: %w", err)
	}

	fmt.Printf("[DEBUG] Total proto files to parse: %d\n", len(protoFiles))
	fmt.Printf("[DEBUG] Total import paths: %d\n", len(paths))

	// Parse each proto file
	for _, protoFile := range protoFiles {
		fmt.Printf("[DEBUG] Parsing proto file: %s\n", protoFile)

		// Build protoc command with all import paths
		args := []string{
			"--descriptor_set_out=" + protoFile + ".pb",
			"--include_imports",
		}

		// Add import paths in order (most specific first)
		for _, p := range paths {
			args = append(args, "--proto_path="+p)
		}

		// Add the proto file
		args = append(args, protoFile)

		fmt.Printf("[DEBUG] Running protoc with args: %v\n", args)

		// Run protoc
		cmd := exec.Command("protoc", args...)
		output, err := cmd.CombinedOutput()
		if err != nil {
			// Clean up the descriptor file if it was created
			os.Remove(protoFile + ".pb")
			return fmt.Errorf("failed to parse proto file %s: %w", protoFile, fmt.Errorf("protoc failed (output: %s): %v", string(output), err))
		}

		// Read the descriptor file
		descriptorData, err := os.ReadFile(protoFile + ".pb")
		if err != nil {
			os.Remove(protoFile + ".pb")
			return fmt.Errorf("failed to read descriptor file: %w", err)
		}

		// Clean up the descriptor file
		os.Remove(protoFile + ".pb")

		// Parse the descriptor file
		var descriptorSet descriptorpb.FileDescriptorSet
		if err := proto.Unmarshal(descriptorData, &descriptorSet); err != nil {
			return fmt.Errorf("failed to parse descriptor file: %w", err)
		}

		// Process the descriptor set
		for _, file := range descriptorSet.GetFile() {
			// Skip if we've already processed this file
			if _, exists := p.parsedFiles[file.GetName()]; exists {
				continue
			}

			// Parse the file descriptor
			fd, err := desc.CreateFileDescriptorFromSet(&descriptorSet)
			if err != nil {
				return fmt.Errorf("failed to create file descriptor for %s: %w", file.GetName(), err)
			}

			// Store the file descriptor
			p.parsedFiles[file.GetName()] = fd

			// Process services
			for _, service := range fd.GetServices() {
				serviceName := service.GetFullyQualifiedName()
				p.services[serviceName] = service

				// Process methods
				for _, method := range service.GetMethods() {
					methodName := method.GetFullyQualifiedName()
					p.methods[methodName] = method
				}
			}

			// Process messages
			for _, message := range fd.GetMessageTypes() {
				messageName := message.GetFullyQualifiedName()
				p.messages[messageName] = message
			}

			// Process enums
			for _, enum := range fd.GetEnumTypes() {
				enumName := enum.GetFullyQualifiedName()
				p.enums[enumName] = enum
			}
		}
	}

	return nil
}

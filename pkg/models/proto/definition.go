package proto

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"time"
)

// ProtoDefinition represents a parsed Protocol Buffer definition file
type ProtoDefinition struct {
	ID              string        `json:"id"`              // Unique identifier
	FilePath        string        `json:"filePath"`        // Path to the proto file
	Content         string        `json:"content"`         // Raw content of the proto file
	Imports         []string      `json:"imports"`         // List of imported proto files
	Services        []Service     `json:"services"`        // List of services defined in the proto
	Messages        []MessageType `json:"messages"`        // List of messages defined in the proto
	CreatedAt       time.Time     `json:"createdAt"`       // Creation timestamp
	UpdatedAt       time.Time     `json:"updatedAt"`       // Last update timestamp
	Description     string        `json:"description"`     // Optional description
	Version         string        `json:"version"`         // Version of the proto definition
	ServerProfileID string        `json:"serverProfileId"` // Linked server profile ID
	ProtoPathID     string        `json:"protoPathId"`     // Linked proto path ID
	LastParsed      time.Time     `json:"lastParsed"`      // Last parsed timestamp
	Error           string        `json:"error"`           // Parsing/validation error, if any

	// New fields for enums and file options
	Enums       []EnumType `json:"enums"`       // List of enums defined in the proto
	FileOptions string     `json:"fileOptions"` // File-level options as string

	// DependencyGraph is built in-memory during parsing and is not persisted to the DB.
	DependencyGraph map[string][]string `json:"dependencyGraph,omitempty"`
}

// Service represents a gRPC service defined in the proto file
type Service struct {
	Name        string   `json:"name"`        // Service name
	Methods     []Method `json:"methods"`     // List of methods in the service
	Description string   `json:"description"` // Service description from comments
}

// Method represents a gRPC method in a service
type Method struct {
	Name            string      `json:"name"`            // Method name
	Description     string      `json:"description"`     // Method description from comments
	InputType       MessageType `json:"inputType"`       // Input message type
	OutputType      MessageType `json:"outputType"`      // Output message type
	ClientStreaming bool        `json:"clientStreaming"` // Whether the method is client streaming
	ServerStreaming bool        `json:"serverStreaming"` // Whether the method is server streaming
}

// MessageType represents a Protocol Buffer message type
type MessageType struct {
	Name        string         `json:"name"`        // Type name
	Fields      []MessageField `json:"fields"`      // List of fields in the message
	Description string         `json:"description"` // Message description from comments
}

// MessageField represents a field in a Protocol Buffer message
type MessageField struct {
	Name        string      `json:"name"`        // Field name
	Number      int32       `json:"number"`      // Field number
	Type        string      `json:"type"`        // Field type (e.g., string, int32, etc.)
	IsRepeated  bool        `json:"isRepeated"`  // Whether the field is repeated
	IsRequired  bool        `json:"isRequired"`  // Whether the field is required (proto2)
	Description string      `json:"description"` // Field description from comments
	Options     FieldOption `json:"options"`     // Field options
}

// FieldOption represents options that can be set on a field
type FieldOption struct {
	Deprecated    bool           `json:"deprecated"`    // Whether the field is deprecated
	JSONName      string         `json:"jsonName"`      // Custom JSON name for the field
	CustomOptions map[string]any `json:"customOptions"` // Custom options defined for the field
}

// EnumType represents a Protocol Buffer enum type
type EnumType struct {
	Name        string      `json:"name"`        // Enum name
	Values      []EnumValue `json:"values"`      // Enum values
	Description string      `json:"description"` // Enum description from comments
}

// EnumValue represents a value in a Protocol Buffer enum
type EnumValue struct {
	Name        string `json:"name"`        // Value name
	Number      int32  `json:"number"`      // Value number
	Description string `json:"description"` // Value description from comments
}

// NewProtoDefinition creates a new ProtoDefinition instance
func NewProtoDefinition(filePath string, content string) *ProtoDefinition {
	now := time.Now()
	return &ProtoDefinition{
		ID:        filepath.Base(filePath), // Using filename as ID for now
		FilePath:  filePath,
		Content:   content,
		CreatedAt: now,
		UpdatedAt: now,
		Version:   "1", // Starting with version 1
		Messages:  make([]MessageType, 0),
	}
}

// Validate checks if the ProtoDefinition is valid
func (pd *ProtoDefinition) Validate() error {
	if pd.FilePath == "" {
		return fmt.Errorf("file path is required")
	}
	if pd.Content == "" {
		return fmt.Errorf("content is required")
	}
	if !filepath.IsAbs(pd.FilePath) {
		return fmt.Errorf("file path must be absolute")
	}
	if filepath.Ext(pd.FilePath) != ".proto" {
		return fmt.Errorf("file must have .proto extension")
	}
	return nil
}

// ToJSON serializes the ProtoDefinition to JSON
func (pd *ProtoDefinition) ToJSON() ([]byte, error) {
	return json.Marshal(pd)
}

// FromJSON deserializes the ProtoDefinition from JSON
func (pd *ProtoDefinition) FromJSON(data []byte) error {
	return json.Unmarshal(data, pd)
}

// AddService adds a service to the ProtoDefinition
func (pd *ProtoDefinition) AddService(service Service) {
	pd.Services = append(pd.Services, service)
	pd.UpdatedAt = time.Now()
}

// AddImport adds an import to the ProtoDefinition
func (pd *ProtoDefinition) AddImport(importPath string) {
	pd.Imports = append(pd.Imports, importPath)
	pd.UpdatedAt = time.Now()
}

// GetService returns a service by name
func (pd *ProtoDefinition) GetService(name string) (*Service, error) {
	for _, svc := range pd.Services {
		if svc.Name == name {
			return &svc, nil
		}
	}
	return nil, fmt.Errorf("service %s not found", name)
}

// GetMethod returns a method from a service by name
func (s *Service) GetMethod(name string) (*Method, error) {
	for _, method := range s.Methods {
		if method.Name == name {
			return &method, nil
		}
	}
	return nil, fmt.Errorf("method %s not found in service %s", name, s.Name)
}

// IsUnary returns true if the method is unary (not streaming)
func (m *Method) IsUnary() bool {
	return !m.ClientStreaming && !m.ServerStreaming
}

// IsBidirectionalStreaming returns true if the method is bidirectional streaming
func (m *Method) IsBidirectionalStreaming() bool {
	return m.ClientStreaming && m.ServerStreaming
}

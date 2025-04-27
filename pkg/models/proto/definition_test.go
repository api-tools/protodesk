package proto

import (
	"path/filepath"
	"testing"
	"time"
)

func TestNewProtoDefinition(t *testing.T) {
	filePath := "/path/to/test.proto"
	content := "syntax = \"proto3\";"
	pd := NewProtoDefinition(filePath, content)

	if pd == nil {
		t.Fatal("NewProtoDefinition returned nil")
	}

	if pd.FilePath != filePath {
		t.Errorf("Expected FilePath %s, got %s", filePath, pd.FilePath)
	}

	if pd.Content != content {
		t.Errorf("Expected Content %s, got %s", content, pd.Content)
	}

	if pd.ID != filepath.Base(filePath) {
		t.Errorf("Expected ID %s, got %s", filepath.Base(filePath), pd.ID)
	}

	if pd.Version != "1" {
		t.Errorf("Expected Version 1, got %s", pd.Version)
	}

	if pd.CreatedAt.IsZero() {
		t.Error("CreatedAt should not be zero")
	}

	if pd.UpdatedAt.IsZero() {
		t.Error("UpdatedAt should not be zero")
	}
}

func TestProtoDefinition_Validate(t *testing.T) {
	tests := []struct {
		name    string
		pd      *ProtoDefinition
		wantErr bool
	}{
		{
			name: "valid definition",
			pd: &ProtoDefinition{
				FilePath: "/path/to/test.proto",
				Content:  "syntax = \"proto3\";",
			},
			wantErr: false,
		},
		{
			name: "empty file path",
			pd: &ProtoDefinition{
				FilePath: "",
				Content:  "syntax = \"proto3\";",
			},
			wantErr: true,
		},
		{
			name: "empty content",
			pd: &ProtoDefinition{
				FilePath: "/path/to/test.proto",
				Content:  "",
			},
			wantErr: true,
		},
		{
			name: "relative file path",
			pd: &ProtoDefinition{
				FilePath: "test.proto",
				Content:  "syntax = \"proto3\";",
			},
			wantErr: true,
		},
		{
			name: "wrong file extension",
			pd: &ProtoDefinition{
				FilePath: "/path/to/test.txt",
				Content:  "syntax = \"proto3\";",
			},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.pd.Validate()
			if (err != nil) != tt.wantErr {
				t.Errorf("Validate() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func TestProtoDefinition_JSON(t *testing.T) {
	pd := &ProtoDefinition{
		ID:          "test.proto",
		FilePath:    "/path/to/test.proto",
		Content:     "syntax = \"proto3\";",
		Imports:     []string{"google/protobuf/timestamp.proto"},
		CreatedAt:   time.Now(),
		UpdatedAt:   time.Now(),
		Description: "Test proto file",
		Version:     "1",
		Services: []Service{
			{
				Name: "TestService",
				Methods: []Method{
					{
						Name: "TestMethod",
						InputType: MessageType{
							Name: "TestRequest",
							Fields: []MessageField{
								{
									Name:   "test_field",
									Number: 1,
									Type:   "string",
								},
							},
						},
						OutputType: MessageType{
							Name: "TestResponse",
							Fields: []MessageField{
								{
									Name:   "result",
									Number: 1,
									Type:   "string",
								},
							},
						},
					},
				},
			},
		},
	}

	// Test ToJSON
	data, err := pd.ToJSON()
	if err != nil {
		t.Fatalf("ToJSON() error = %v", err)
	}

	// Test FromJSON
	newPD := &ProtoDefinition{}
	err = newPD.FromJSON(data)
	if err != nil {
		t.Fatalf("FromJSON() error = %v", err)
	}

	// Compare fields
	if newPD.ID != pd.ID {
		t.Errorf("ID mismatch: got %v, want %v", newPD.ID, pd.ID)
	}
	if newPD.FilePath != pd.FilePath {
		t.Errorf("FilePath mismatch: got %v, want %v", newPD.FilePath, pd.FilePath)
	}
	if len(newPD.Services) != len(pd.Services) {
		t.Errorf("Services length mismatch: got %v, want %v", len(newPD.Services), len(pd.Services))
	}
	if len(newPD.Services[0].Methods) != len(pd.Services[0].Methods) {
		t.Errorf("Methods length mismatch: got %v, want %v", len(newPD.Services[0].Methods), len(pd.Services[0].Methods))
	}
}

func TestService_GetMethod(t *testing.T) {
	service := Service{
		Name: "TestService",
		Methods: []Method{
			{Name: "Method1"},
			{Name: "Method2"},
		},
	}

	// Test finding existing method
	method, err := service.GetMethod("Method1")
	if err != nil {
		t.Errorf("GetMethod() error = %v", err)
	}
	if method.Name != "Method1" {
		t.Errorf("GetMethod() got = %v, want Method1", method.Name)
	}

	// Test finding non-existent method
	_, err = service.GetMethod("NonExistent")
	if err == nil {
		t.Error("GetMethod() expected error for non-existent method")
	}
}

func TestMethod_Streaming(t *testing.T) {
	tests := []struct {
		name              string
		method            Method
		wantUnary         bool
		wantBidirectional bool
	}{
		{
			name:              "unary method",
			method:            Method{ClientStreaming: false, ServerStreaming: false},
			wantUnary:         true,
			wantBidirectional: false,
		},
		{
			name:              "client streaming",
			method:            Method{ClientStreaming: true, ServerStreaming: false},
			wantUnary:         false,
			wantBidirectional: false,
		},
		{
			name:              "server streaming",
			method:            Method{ClientStreaming: false, ServerStreaming: true},
			wantUnary:         false,
			wantBidirectional: false,
		},
		{
			name:              "bidirectional streaming",
			method:            Method{ClientStreaming: true, ServerStreaming: true},
			wantUnary:         false,
			wantBidirectional: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.method.IsUnary(); got != tt.wantUnary {
				t.Errorf("IsUnary() = %v, want %v", got, tt.wantUnary)
			}
			if got := tt.method.IsBidirectionalStreaming(); got != tt.wantBidirectional {
				t.Errorf("IsBidirectionalStreaming() = %v, want %v", got, tt.wantBidirectional)
			}
		})
	}
}

func TestProtoDefinition_AddService(t *testing.T) {
	pd := NewProtoDefinition("/path/to/test.proto", "content")
	service := Service{Name: "TestService"}

	originalTime := pd.UpdatedAt
	time.Sleep(time.Millisecond) // Ensure time difference

	pd.AddService(service)

	if len(pd.Services) != 1 {
		t.Errorf("Expected 1 service, got %d", len(pd.Services))
	}

	if pd.Services[0].Name != "TestService" {
		t.Errorf("Expected service name TestService, got %s", pd.Services[0].Name)
	}

	if !pd.UpdatedAt.After(originalTime) {
		t.Error("UpdatedAt was not updated")
	}
}

func TestProtoDefinition_AddImport(t *testing.T) {
	pd := NewProtoDefinition("/path/to/test.proto", "content")
	importPath := "google/protobuf/timestamp.proto"

	originalTime := pd.UpdatedAt
	time.Sleep(time.Millisecond) // Ensure time difference

	pd.AddImport(importPath)

	if len(pd.Imports) != 1 {
		t.Errorf("Expected 1 import, got %d", len(pd.Imports))
	}

	if pd.Imports[0] != importPath {
		t.Errorf("Expected import path %s, got %s", importPath, pd.Imports[0])
	}

	if !pd.UpdatedAt.After(originalTime) {
		t.Error("UpdatedAt was not updated")
	}
}

func TestProtoDefinition_GetService(t *testing.T) {
	pd := &ProtoDefinition{
		Services: []Service{
			{Name: "Service1"},
			{Name: "Service2"},
		},
	}

	// Test finding existing service
	service, err := pd.GetService("Service1")
	if err != nil {
		t.Errorf("GetService() error = %v", err)
	}
	if service.Name != "Service1" {
		t.Errorf("GetService() got = %v, want Service1", service.Name)
	}

	// Test finding non-existent service
	_, err = pd.GetService("NonExistent")
	if err == nil {
		t.Error("GetService() expected error for non-existent service")
	}
}

package proto

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestParser_ParseFile(t *testing.T) {
	// Create a temporary directory for test files
	tmpDir, err := os.MkdirTemp("", "proto-test-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	// Create a test proto file
	protoContent := `
syntax = "proto3";

package test;

import "google/protobuf/empty.proto";

// TestService is a test service
service TestService {
    // TestMethod is a test method
    rpc TestMethod(google.protobuf.Empty) returns (google.protobuf.Empty) {}
}
`
	protoFile := filepath.Join(tmpDir, "test.proto")
	err = os.WriteFile(protoFile, []byte(protoContent), 0644)
	require.NoError(t, err)

	// Initialize parser
	parser := &Parser{}

	// Parse the proto file
	result, err := parser.ParseFile(protoFile)
	require.NoError(t, err)
	require.NotNil(t, result)

	// Verify the parsed content
	assert.Equal(t, filepath.Base(protoFile), filepath.Base(result.FilePath))
	assert.Contains(t, result.Imports, "google/protobuf/empty.proto")

	// Verify service
	require.Len(t, result.Services, 1)
	service := result.Services[0]
	assert.Equal(t, "TestService", service.Name)
	assert.Equal(t, "", service.Description)

	// Verify method
	require.Len(t, service.Methods, 1)
	method := service.Methods[0]
	assert.Equal(t, "TestMethod", method.Name)
	assert.Equal(t, "", method.Description)
	assert.Equal(t, "Empty", method.InputType.Name)
	assert.Equal(t, "Empty", method.OutputType.Name)
}

func TestParser_ParseFile_InvalidFile(t *testing.T) {
	parser := &Parser{}

	// Test with non-existent file
	result, err := parser.ParseFile("nonexistent.proto")
	assert.Error(t, err)
	assert.Nil(t, result)

	// Test with invalid proto content
	tmpDir, err := os.MkdirTemp("", "proto-test-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	invalidProto := `
syntax = "proto3"  // Missing semicolon
service InvalidService {
	invalid content
}
`
	invalidFile := filepath.Join(tmpDir, "invalid.proto")
	err = os.WriteFile(invalidFile, []byte(invalidProto), 0644)
	require.NoError(t, err)

	result, err = parser.ParseFile(invalidFile)
	assert.Error(t, err)
	assert.Nil(t, result)
}

func TestParser_parseProtoFile(t *testing.T) {
	// Create a temporary directory for test files
	tmpDir, err := os.MkdirTemp("", "proto-test-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	// Create a valid proto file
	validProto := `
syntax = "proto3";
package test;
message TestMessage {
    string field = 1;
}
`
	validFile := filepath.Join(tmpDir, "valid.proto")
	err = os.WriteFile(validFile, []byte(validProto), 0644)
	require.NoError(t, err)

	// Read the file content
	content, err := os.ReadFile(validFile)
	require.NoError(t, err)

	parser := &Parser{}
	descriptor, err := parser.parseProtoFile(validFile, content)
	require.NoError(t, err)
	require.NotNil(t, descriptor)
	assert.NotNil(t, descriptor.Path())
}

func TestParser_ParseFile_MultipleServicesAndMethods(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "proto-test-multi-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	protoContent := `
syntax = "proto3";

package testmulti;

service ServiceOne {
    rpc MethodA (RequestA) returns (ResponseA) {}
    rpc MethodB (RequestB) returns (ResponseB) {}
}

service ServiceTwo {
    rpc MethodC (RequestC) returns (ResponseC) {}
}

message RequestA { string foo = 1; }
message ResponseA { string bar = 1; }
message RequestB { int32 id = 1; }
message ResponseB { bool ok = 1; }
message RequestC { double value = 1; }
message ResponseC { bytes data = 1; }
`
	protoFile := filepath.Join(tmpDir, "multi.proto")
	err = os.WriteFile(protoFile, []byte(protoContent), 0644)
	require.NoError(t, err)

	parser := &Parser{}
	result, err := parser.ParseFile(protoFile)
	require.NoError(t, err)
	require.NotNil(t, result)

	require.Len(t, result.Services, 2)
	assert.Equal(t, "ServiceOne", result.Services[0].Name)
	assert.Equal(t, "ServiceTwo", result.Services[1].Name)
	assert.Len(t, result.Services[0].Methods, 2)
	assert.Len(t, result.Services[1].Methods, 1)
}

func TestParser_ParseFile_NestedImports(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "proto-test-nested-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	// Create base imported proto
	baseProto := `
syntax = "proto3";
package base;
import "google/protobuf/timestamp.proto";
message BaseMsg {
    google.protobuf.Timestamp ts = 1;
}`
	baseProtoFile := filepath.Join(tmpDir, "base.proto")
	err = os.WriteFile(baseProtoFile, []byte(baseProto), 0644)
	require.NoError(t, err)

	// Create main proto that imports base.proto
	mainProto := `
syntax = "proto3";
package main;
import "base.proto";
service MainService {
    rpc UseBase (base.BaseMsg) returns (base.BaseMsg) {}
}`
	mainProtoFile := filepath.Join(tmpDir, "main.proto")
	err = os.WriteFile(mainProtoFile, []byte(mainProto), 0644)
	require.NoError(t, err)

	parser := NewParser([]string{tmpDir})
	result, err := parser.ParseFile(mainProtoFile)
	require.NoError(t, err)
	require.NotNil(t, result)
	assert.Contains(t, result.Imports, "base.proto")
	assert.Equal(t, "MainService", result.Services[0].Name)
}

func TestParser_ParseFile_MissingImport(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "proto-test-missingimport-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	protoContent := `
syntax = "proto3";
import "doesnotexist.proto";
message Foo { string bar = 1; }
`
	protoFile := filepath.Join(tmpDir, "missingimport.proto")
	err = os.WriteFile(protoFile, []byte(protoContent), 0644)
	require.NoError(t, err)

	parser := &Parser{}
	result, err := parser.ParseFile(protoFile)
	assert.Error(t, err)
	assert.Nil(t, result)
}

func TestParser_ParseFile_MultipleWellKnownTypes(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "proto-test-wkt-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	protoContent := `
syntax = "proto3";
import "google/protobuf/empty.proto";
import "google/protobuf/timestamp.proto";
message UsesWKT {
    google.protobuf.Empty e = 1;
    google.protobuf.Timestamp ts = 2;
}`
	protoFile := filepath.Join(tmpDir, "wkt.proto")
	err = os.WriteFile(protoFile, []byte(protoContent), 0644)
	require.NoError(t, err)

	parser := &Parser{}
	result, err := parser.ParseFile(protoFile)
	require.NoError(t, err)
	require.NotNil(t, result)
	assert.Contains(t, result.Imports, "google/protobuf/empty.proto")
	assert.Contains(t, result.Imports, "google/protobuf/timestamp.proto")
}

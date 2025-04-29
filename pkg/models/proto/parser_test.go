package proto

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func wellKnownTypesAvailable() bool {
	path := os.Getenv("PROTOBUF_WELL_KNOWN_TYPES_PATH")
	if path == "" {
		return false
	}
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func TestParser_ParseFile(t *testing.T) {
	if !wellKnownTypesAvailable() {
		t.Skip("Skipping: PROTOBUF_WELL_KNOWN_TYPES_PATH not set or directory does not exist")
	}
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
	if !wellKnownTypesAvailable() {
		t.Skip("Skipping: PROTOBUF_WELL_KNOWN_TYPES_PATH not set or directory does not exist")
	}
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
	if !wellKnownTypesAvailable() {
		t.Skip("Skipping: PROTOBUF_WELL_KNOWN_TYPES_PATH not set or directory does not exist")
	}
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

func TestParser_CircularImportChain(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "proto-test-circular-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	// Create three proto files forming a circular import: a -> b -> c -> a
	aProto := `syntax = "proto3"; import "b.proto"; message A {}`
	bProto := `syntax = "proto3"; import "c.proto"; message B {}`
	cProto := `syntax = "proto3"; import "a.proto"; message C {}`

	aFile := filepath.Join(tmpDir, "a.proto")
	bFile := filepath.Join(tmpDir, "b.proto")
	cFile := filepath.Join(tmpDir, "c.proto")

	require.NoError(t, os.WriteFile(aFile, []byte(aProto), 0644))
	require.NoError(t, os.WriteFile(bFile, []byte(bProto), 0644))
	require.NoError(t, os.WriteFile(cFile, []byte(cProto), 0644))

	parser := NewParser([]string{tmpDir})
	_, err = parser.ParseFile(aFile)
	assert.Error(t, err)
	// Check for protoc's recursive import error message
	assert.Contains(t, err.Error(), "File recursively imports itself")
}

func TestParser_MalformedFieldType(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "proto-test-malformed-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	malformedProto := `syntax = "proto3"; message Bad { invalidtype foo = 1; }`
	file := filepath.Join(tmpDir, "bad.proto")
	require.NoError(t, os.WriteFile(file, []byte(malformedProto), 0644))

	parser := NewParser([]string{tmpDir})
	_, err = parser.ParseFile(file)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "protoc failed")
}

func TestParser_LargeProtoFile(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "proto-test-large-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	// Generate a proto file with 50 services, each with 10 methods
	services := ""
	for i := 0; i < 50; i++ {
		services += fmt.Sprintf("service S%d {\n", i)
		for j := 0; j < 10; j++ {
			services += fmt.Sprintf("  rpc M%d (Req) returns (Res) {}\n", j)
		}
		services += "}\n"
	}
	largeProto := `syntax = "proto3"; message Req { string foo = 1; } message Res { string bar = 1; }` + services
	file := filepath.Join(tmpDir, "large.proto")
	require.NoError(t, os.WriteFile(file, []byte(largeProto), 0644))

	parser := NewParser([]string{tmpDir})
	result, err := parser.ParseFile(file)
	require.NoError(t, err)
	require.NotNil(t, result)
	assert.GreaterOrEqual(t, len(result.Services), 40)
}

func TestParser_ImportFromMultipleLocations(t *testing.T) {
	tmpDir1, err := os.MkdirTemp("", "proto-test-import1-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir1)
	tmpDir2, err := os.MkdirTemp("", "proto-test-import2-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir2)

	commonProto := `syntax = "proto3"; message Shared { string foo = 1; }`
	file1 := filepath.Join(tmpDir1, "shared.proto")
	file2 := filepath.Join(tmpDir2, "shared.proto")
	require.NoError(t, os.WriteFile(file1, []byte(commonProto), 0644))
	require.NoError(t, os.WriteFile(file2, []byte(commonProto), 0644))

	mainProto := `syntax = "proto3"; import "shared.proto"; message Main { Shared s = 1; }`
	mainFile := filepath.Join(tmpDir1, "main.proto")
	require.NoError(t, os.WriteFile(mainFile, []byte(mainProto), 0644))

	parser := NewParser([]string{tmpDir1, tmpDir2})
	result, err := parser.ParseFile(mainFile)
	require.NoError(t, err)
	require.NotNil(t, result)
	assert.Contains(t, result.Imports, "shared.proto")
}

func TestParser_EnumExtractionEdgeCase(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "proto-test-enum-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	protoContent := `syntax = "proto3"; enum Foo { FOO_UNSPECIFIED = 0; FOO_BAR = 1; }`
	file := filepath.Join(tmpDir, "enum.proto")
	require.NoError(t, os.WriteFile(file, []byte(protoContent), 0644))

	parser := NewParser([]string{tmpDir})
	result, err := parser.ParseFile(file)
	require.NoError(t, err)
	require.NotNil(t, result)
	assert.GreaterOrEqual(t, len(result.Enums), 1)
	assert.Equal(t, "Foo", result.Enums[0].Name)
	assert.Equal(t, "FOO_UNSPECIFIED", result.Enums[0].Values[0].Name)
}

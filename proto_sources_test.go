package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFindProtoFilesInFolderRecursively(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "service.proto"), `syntax = "proto3"; package test;`)
	writeTestFile(t, filepath.Join(root, "nested", "types.proto"), `syntax = "proto3"; package test;`)
	writeTestFile(t, filepath.Join(root, "notes.txt"), `ignore me`)

	files, err := findProtoFilesInFolder(root)
	if err != nil {
		t.Fatalf("findProtoFilesInFolder() error = %v", err)
	}

	if len(files) != 2 {
		t.Fatalf("expected 2 proto files, got %d: %v", len(files), files)
	}
	if !strings.HasSuffix(files[0], "nested/types.proto") && !strings.HasSuffix(files[1], "nested/types.proto") {
		t.Fatalf("expected nested proto file in results: %v", files)
	}
}

func TestValidateProtoSourcesValidFolder(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "common", "types.proto"), `syntax = "proto3"; package test.common; message Thing { string id = 1; }`)
	writeTestFile(t, filepath.Join(root, "service.proto"), `syntax = "proto3"; package test; import "common/types.proto"; service TestService { rpc Get(test.common.Thing) returns (test.common.Thing); }`)

	response := validateProtoSources(context.Background(), ValidateProtoSourcesRequest{
		ProtoFolders: []string{root},
	})

	if !response.Valid {
		t.Fatalf("expected valid proto sources, got errors: %v", response.Errors)
	}
	if response.FileCount != 2 {
		t.Fatalf("expected 2 files, got %d", response.FileCount)
	}
}

func TestValidateProtoSourcesRejectsInvalidProto(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "broken.proto"), `syntax = "proto3"; package test; message Broken {`)

	response := validateProtoSources(context.Background(), ValidateProtoSourcesRequest{
		ProtoFolders: []string{root},
	})

	if response.Valid {
		t.Fatal("expected invalid proto sources")
	}
	if len(response.Errors) == 0 {
		t.Fatal("expected validation errors")
	}
}

func TestValidateProtoSourcesRejectsImportCycle(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "a.proto"), `syntax = "proto3"; package cycle; import "b.proto"; message A {}`)
	writeTestFile(t, filepath.Join(root, "b.proto"), `syntax = "proto3"; package cycle; import "a.proto"; message B {}`)

	response := validateProtoSources(context.Background(), ValidateProtoSourcesRequest{
		ProtoFolders: []string{root},
	})

	if response.Valid {
		t.Fatal("expected circular imports to be invalid")
	}
	if len(response.Errors) == 0 {
		t.Fatal("expected cycle validation error")
	}
}

func TestValidateProtoSourcesRejectsImportsOutsideConfiguredRoot(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "workspace")
	writeTestFile(t, filepath.Join(parent, "outside.proto"), `syntax = "proto3"; package outside; message Secret {}`)
	writeTestFile(t, filepath.Join(root, "service.proto"), `syntax = "proto3"; package test; import "../outside.proto"; message Request {}`)

	response := validateProtoSources(context.Background(), ValidateProtoSourcesRequest{
		ProtoFolders: []string{root},
	})

	if response.Valid {
		t.Fatal("expected parent-directory proto import to be rejected")
	}
}

func writeTestFile(t *testing.T, path string, contents string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("MkdirAll() error = %v", err)
	}
	if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}
}

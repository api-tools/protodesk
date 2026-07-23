package main

import (
	"context"
	"path/filepath"
	"testing"
)

func TestWorkspaceExportAndImportRoundTrip(t *testing.T) {
	source := newTestServerProfileStore(t)
	ctx := context.Background()

	server, err := source.create(ctx, SaveServerProfileRequest{
		Name:              "Sports API Local",
		Address:           "localhost:50051",
		ReflectionEnabled: true,
		ProtoFiles:        []string{"/tmp/sports.proto"},
		ProtoFolders:      []string{"/tmp/protos"},
		MetadataJSON:      `{"authorization":"Bearer {{AUTH_TOKEN}}"}`,
	})
	if err != nil {
		t.Fatalf("create server: %v", err)
	}
	collection, err := source.createCollection(ctx, SaveCollectionRequest{Name: "Sports examples"})
	if err != nil {
		t.Fatalf("create collection: %v", err)
	}
	if _, err := source.createCollectionRequest(ctx, SaveCollectionRequestItemRequest{
		CollectionID:        collection.ID,
		Name:                "Live matches",
		ServerID:            server.ID,
		ServerName:          server.Name,
		ServerAddress:       server.Address,
		ServiceName:         "sports.MatchService",
		MethodName:          "GetMatches",
		FullMethod:          "/sports.MatchService/GetMatches",
		RequestJSON:         `{"live":true}`,
		RequestMetadataJSON: `{"x-tenant-id":"{{TENANT_ID}}"}`,
	}); err != nil {
		t.Fatalf("create request: %v", err)
	}

	file, err := source.exportWorkspace(ctx)
	if err != nil {
		t.Fatalf("export workspace: %v", err)
	}
	if file.Kind != workspaceExportKind || file.Version != workspaceExportVersion {
		t.Fatalf("unexpected export identity: %#v", file)
	}
	if len(file.Servers) != 1 || len(file.Collections) != 1 || len(file.Collections[0].Requests) != 1 {
		t.Fatalf("unexpected export contents: %#v", file)
	}

	target := newTestServerProfileStore(t)
	result, err := target.importWorkspace(ctx, file)
	if err != nil {
		t.Fatalf("import workspace: %v", err)
	}
	if result.ServerCount != 1 || result.CollectionCount != 1 || result.SavedRequestCount != 1 {
		t.Fatalf("unexpected import result: %#v", result)
	}

	importedServers, err := target.list(ctx)
	if err != nil {
		t.Fatalf("list imported servers: %v", err)
	}
	importedCollections, err := target.listCollections(ctx)
	if err != nil {
		t.Fatalf("list imported collections: %v", err)
	}
	if importedServers[0].ID == server.ID {
		t.Fatal("expected imported server to receive a new id")
	}
	if importedCollections[0].ID == collection.ID {
		t.Fatal("expected imported collection to receive a new id")
	}
	importedRequest := importedCollections[0].Requests[0]
	if importedRequest.ServerID != importedServers[0].ID {
		t.Fatalf("expected request server id to be remapped, got %#v", importedRequest)
	}
	if importedRequest.RequestJSON != `{"live":true}` || importedRequest.RequestMetadataJSON != `{"x-tenant-id":"{{TENANT_ID}}"}` {
		t.Fatalf("request JSON did not round trip: %#v", importedRequest)
	}
}

func TestWorkspaceExportFileReadWriteValidation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "workspace.json")
	file := WorkspaceExportFile{
		Version:     workspaceExportVersion,
		Kind:        workspaceExportKind,
		WorkspaceID: localWorkspaceID,
	}

	if err := writeWorkspaceExport(path, file); err != nil {
		t.Fatalf("write export: %v", err)
	}
	read, err := readWorkspaceExport(path)
	if err != nil {
		t.Fatalf("read export: %v", err)
	}
	if read.Kind != workspaceExportKind {
		t.Fatalf("unexpected export kind: %#v", read)
	}

	bad := file
	bad.Version = 99
	if err := validateWorkspaceExportFile(bad); err == nil {
		t.Fatal("expected unsupported version to fail")
	}
}

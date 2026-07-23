package main

import (
	"context"
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
)

func newTestServerProfileStore(t *testing.T) *serverProfileStore {
	t.Helper()

	store, err := newServerProfileStore(filepath.Join(t.TempDir(), "protodesk.sqlite"))
	if err != nil {
		t.Fatalf("newServerProfileStore: %v", err)
	}
	t.Cleanup(func() {
		if err := store.close(); err != nil {
			t.Fatalf("close store: %v", err)
		}
	})
	return store
}

func TestServerProfileStoreInitializesEmptySchema(t *testing.T) {
	store := newTestServerProfileStore(t)

	profiles, err := store.list(context.Background())
	if err != nil {
		t.Fatalf("list profiles: %v", err)
	}
	if len(profiles) != 0 {
		t.Fatalf("expected empty profile list, got %#v", profiles)
	}
}

func TestServerProfileStoreCreateListUpdateDelete(t *testing.T) {
	store := newTestServerProfileStore(t)
	ctx := context.Background()

	created, err := store.create(ctx, SaveServerProfileRequest{
		Name:              " Local gRPC ",
		Address:           "localhost:50051",
		TLSEnabled:        false,
		ReflectionEnabled: true,
		ProtoFiles:        []string{"/tmp/protos/service.proto"},
		ProtoFolders:      []string{"/tmp/protos"},
		MetadataJSON:      `{"x-team":"platform"}`,
	})
	if err != nil {
		t.Fatalf("create profile: %v", err)
	}
	if created.WorkspaceID != localWorkspaceID {
		t.Fatalf("expected local workspace id, got %q", created.WorkspaceID)
	}
	if created.ID == "" {
		t.Fatal("expected generated profile id")
	}

	profiles, err := store.list(ctx)
	if err != nil {
		t.Fatalf("list profiles: %v", err)
	}
	if len(profiles) != 1 {
		t.Fatalf("expected one profile, got %#v", profiles)
	}
	if profiles[0].Name != "Local gRPC" || profiles[0].ProtoFiles[0] != "/tmp/protos/service.proto" {
		t.Fatalf("unexpected listed profile: %#v", profiles[0])
	}

	updated, err := store.update(ctx, created.ID, SaveServerProfileRequest{
		Name:              "Staging",
		Address:           "staging.example.com:443",
		TLSEnabled:        true,
		ReflectionEnabled: false,
		ProtoFiles:        []string{"/tmp/protos/admin.proto"},
		ProtoFolders:      []string{"/tmp/vendor"},
		MetadataJSON:      `{"authorization":"Bearer {{AUTH_TOKEN}}"}`,
	})
	if err != nil {
		t.Fatalf("update profile: %v", err)
	}
	if updated.WorkspaceID != localWorkspaceID || updated.ID != created.ID {
		t.Fatalf("update should preserve identity, got %#v", updated)
	}
	if !updated.TLSEnabled || updated.ReflectionEnabled {
		t.Fatalf("unexpected updated flags: %#v", updated)
	}

	if err := store.delete(ctx, created.ID); err != nil {
		t.Fatalf("delete profile: %v", err)
	}
	profiles, err = store.list(ctx)
	if err != nil {
		t.Fatalf("list after delete: %v", err)
	}
	if len(profiles) != 0 {
		t.Fatalf("expected deleted profile list to be empty, got %#v", profiles)
	}
}

func TestServerProfileStoreRejectsInvalidMetadata(t *testing.T) {
	store := newTestServerProfileStore(t)

	_, err := store.create(context.Background(), SaveServerProfileRequest{
		Name:              "Bad Metadata",
		Address:           "localhost:50051",
		ReflectionEnabled: true,
		MetadataJSON:      `{"authorization":123}`,
	})
	if err == nil || !strings.Contains(err.Error(), "cannot unmarshal number") {
		t.Fatalf("expected invalid metadata error, got %v", err)
	}
}

func TestServerProfileStoreReturnsCorruptProtoJSONError(t *testing.T) {
	store := newTestServerProfileStore(t)
	ctx := context.Background()

	_, err := store.db.ExecContext(ctx, `
		INSERT INTO servers (
			workspace_id, id, name, address, tls_enabled, reflection_enabled,
			proto_files_json, proto_folders_json, metadata_json, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, localWorkspaceID, "corrupt", "Corrupt", "localhost:50051", 0, 1, "{", "[]", "{}", "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z")
	if err != nil {
		t.Fatalf("insert corrupt profile: %v", err)
	}

	_, err = store.list(ctx)
	if err == nil || !strings.Contains(err.Error(), "invalid proto files JSON") {
		t.Fatalf("expected corrupt proto JSON error, got %v", err)
	}
}

func TestServerProfileStoreUpdateMissingProfile(t *testing.T) {
	store := newTestServerProfileStore(t)

	_, err := store.update(context.Background(), "missing", SaveServerProfileRequest{
		Name:              "Missing",
		Address:           "localhost:50051",
		ReflectionEnabled: true,
		MetadataJSON:      "{}",
	})
	if err == nil || !strings.Contains(err.Error(), "not found") {
		t.Fatalf("expected missing profile error, got %v", err)
	}
}

func TestScanServerProfileRejectsCorruptFoldersJSON(t *testing.T) {
	store := newTestServerProfileStore(t)
	row := store.db.QueryRow(`
		SELECT workspace_id, id, name, address, tls_enabled, reflection_enabled,
			proto_files_json, proto_folders_json, metadata_json
		FROM (
			SELECT ? AS workspace_id, ? AS id, ? AS name, ? AS address,
				? AS tls_enabled, ? AS reflection_enabled, ? AS proto_files_json,
				? AS proto_folders_json, ? AS metadata_json
		)
	`, localWorkspaceID, "bad-folders", "Bad", "localhost:50051", 0, 1, "[]", "{", "{}")

	_, err := scanServerProfile(row)
	if err == nil || !strings.Contains(err.Error(), "invalid proto folders JSON") {
		t.Fatalf("expected corrupt proto folders JSON error, got %v", err)
	}
}

func TestServerProfileStoreCanOpenExistingDatabase(t *testing.T) {
	path := filepath.Join(t.TempDir(), "protodesk.sqlite")
	store, err := newServerProfileStore(path)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if _, err := store.create(context.Background(), SaveServerProfileRequest{
		Name:              "Persisted",
		Address:           "localhost:50051",
		ReflectionEnabled: true,
		MetadataJSON:      "{}",
	}); err != nil {
		t.Fatalf("create persisted profile: %v", err)
	}
	if err := store.close(); err != nil {
		t.Fatalf("close first store: %v", err)
	}

	reopened, err := newServerProfileStore(path)
	if err != nil {
		t.Fatalf("reopen store: %v", err)
	}
	defer reopened.close()

	profiles, err := reopened.list(context.Background())
	if err != nil {
		t.Fatalf("list reopened profiles: %v", err)
	}
	if len(profiles) != 1 || profiles[0].Name != "Persisted" {
		t.Fatalf("expected persisted profile, got %#v", profiles)
	}
}

func TestServerProfileStoreHistoryCreateListDeleteClear(t *testing.T) {
	store := newTestServerProfileStore(t)
	ctx := context.Background()

	first, err := store.createHistory(ctx, SaveHistoryItemRequest{
		ServerID:            "server-1",
		ServerName:          "Local",
		ServerAddress:       "localhost:50051",
		ServiceName:         "fieldlab.AdminService",
		MethodName:          "ListTenants",
		FullMethod:          "/fieldlab.AdminService/ListTenants",
		RequestJSON:         `{"pageSize":10}`,
		RequestMetadataJSON: `{"authorization":"Bearer {{AUTH_TOKEN}}"}`,
		ResponseJSON:        `{"tenants":[]}`,
		StatusCode:          "OK",
		StatusMessage:       "ok",
		DurationMs:          2,
	})
	if err != nil {
		t.Fatalf("create first history item: %v", err)
	}
	second, err := store.createHistory(ctx, SaveHistoryItemRequest{
		ServerID:            "server-1",
		ServerName:          "Local",
		ServerAddress:       "localhost:50051",
		ServiceName:         "fieldlab.AdminService",
		MethodName:          "GetTenant",
		FullMethod:          "/fieldlab.AdminService/GetTenant",
		RequestJSON:         `{"id":"missing"}`,
		RequestMetadataJSON: `{}`,
		ResponseJSON:        `{}`,
		StatusCode:          "NOT_FOUND",
		StatusMessage:       "missing",
		DurationMs:          4,
		Error:               "tenant not found",
	})
	if err != nil {
		t.Fatalf("create second history item: %v", err)
	}

	items, err := store.listHistory(ctx, 1)
	if err != nil {
		t.Fatalf("list limited history: %v", err)
	}
	if len(items) != 1 || items[0].ID != second.ID {
		t.Fatalf("expected newest limited item, got %#v", items)
	}
	if items[0].RequestMetadataJSON != `{}` || items[0].Error != "tenant not found" {
		t.Fatalf("expected history fields to round trip, got %#v", items[0])
	}

	if err := store.deleteHistory(ctx, second.ID); err != nil {
		t.Fatalf("delete history item: %v", err)
	}
	items, err = store.listHistory(ctx, 100)
	if err != nil {
		t.Fatalf("list after delete: %v", err)
	}
	if len(items) != 1 || items[0].ID != first.ID {
		t.Fatalf("expected only first history item after delete, got %#v", items)
	}

	if err := store.clearHistory(ctx); err != nil {
		t.Fatalf("clear history: %v", err)
	}
	items, err = store.listHistory(ctx, 100)
	if err != nil {
		t.Fatalf("list after clear: %v", err)
	}
	if len(items) != 0 {
		t.Fatalf("expected empty history after clear, got %#v", items)
	}
}

func TestServerProfileStoreRejectsInvalidHistoryJSON(t *testing.T) {
	store := newTestServerProfileStore(t)

	_, err := store.createHistory(context.Background(), SaveHistoryItemRequest{
		ServerAddress:       "localhost:50051",
		FullMethod:          "/fieldlab.AdminService/ListTenants",
		RequestJSON:         "{",
		RequestMetadataJSON: "{}",
		ResponseJSON:        "{}",
		StatusCode:          "OK",
	})
	if err == nil || !strings.Contains(err.Error(), "request JSON") {
		t.Fatalf("expected invalid request JSON error, got %v", err)
	}
}

func TestServerProfileStoreCollectionsCRUD(t *testing.T) {
	store := newTestServerProfileStore(t)
	ctx := context.Background()

	collection, err := store.createCollection(ctx, SaveCollectionRequest{
		Name:        "Personal",
		Description: "Local reusable requests",
	})
	if err != nil {
		t.Fatalf("create collection: %v", err)
	}
	if collection.WorkspaceID != localWorkspaceID || collection.ID == "" {
		t.Fatalf("expected local collection identity, got %#v", collection)
	}

	request, err := store.createCollectionRequest(ctx, SaveCollectionRequestItemRequest{
		CollectionID:        collection.ID,
		Name:                "List tenants",
		ServerID:            "server-1",
		ServerName:          "Local",
		ServerAddress:       "localhost:50051",
		ServiceName:         "fieldlab.admin.AdminService",
		MethodName:          "ListTenants",
		FullMethod:          "/fieldlab.admin.AdminService/ListTenants",
		RequestJSON:         `{"pageSize":10}`,
		RequestMetadataJSON: `{"authorization":"Bearer {{AUTH_TOKEN}}"}`,
	})
	if err != nil {
		t.Fatalf("create collection request: %v", err)
	}

	collections, err := store.listCollections(ctx)
	if err != nil {
		t.Fatalf("list collections: %v", err)
	}
	if len(collections) != 1 || len(collections[0].Requests) != 1 {
		t.Fatalf("expected collection with request, got %#v", collections)
	}
	if collections[0].Requests[0].RequestMetadataJSON != `{"authorization":"Bearer {{AUTH_TOKEN}}"}` {
		t.Fatalf("metadata JSON did not round trip: %#v", collections[0].Requests[0])
	}

	updatedCollection, err := store.updateCollection(ctx, collection.ID, SaveCollectionRequest{
		Name:        "Shared local",
		Description: "Updated",
	})
	if err != nil {
		t.Fatalf("update collection: %v", err)
	}
	if updatedCollection.Name != "Shared local" || updatedCollection.CreatedAt == "" {
		t.Fatalf("unexpected updated collection: %#v", updatedCollection)
	}

	updatedRequest, err := store.updateCollectionRequest(ctx, request.ID, SaveCollectionRequestItemRequest{
		CollectionID:        collection.ID,
		Name:                "List tenants updated",
		ServerAddress:       "localhost:50051",
		ServiceName:         "fieldlab.admin.AdminService",
		MethodName:          "ListTenants",
		FullMethod:          "/fieldlab.admin.AdminService/ListTenants",
		RequestJSON:         `{"pageSize":20}`,
		RequestMetadataJSON: `{}`,
	})
	if err != nil {
		t.Fatalf("update collection request: %v", err)
	}
	if updatedRequest.Name != "List tenants updated" || updatedRequest.RequestJSON != `{"pageSize":20}` {
		t.Fatalf("unexpected updated request: %#v", updatedRequest)
	}

	if err := store.deleteCollectionRequest(ctx, request.ID); err != nil {
		t.Fatalf("delete collection request: %v", err)
	}
	collections, err = store.listCollections(ctx)
	if err != nil {
		t.Fatalf("list after request delete: %v", err)
	}
	if len(collections[0].Requests) != 0 {
		t.Fatalf("expected request to be deleted, got %#v", collections[0].Requests)
	}
}

func TestServerProfileStoreDeleteCollectionRemovesRequests(t *testing.T) {
	store := newTestServerProfileStore(t)
	ctx := context.Background()

	collection, err := store.createCollection(ctx, SaveCollectionRequest{Name: "Personal"})
	if err != nil {
		t.Fatalf("create collection: %v", err)
	}
	if _, err := store.createCollectionRequest(ctx, SaveCollectionRequestItemRequest{
		CollectionID:        collection.ID,
		Name:                "Saved",
		ServerAddress:       "localhost:50051",
		FullMethod:          "/fieldlab.Service/Saved",
		RequestJSON:         `{}`,
		RequestMetadataJSON: `{}`,
	}); err != nil {
		t.Fatalf("create request: %v", err)
	}

	if err := store.deleteCollection(ctx, collection.ID); err != nil {
		t.Fatalf("delete collection: %v", err)
	}
	collections, err := store.listCollections(ctx)
	if err != nil {
		t.Fatalf("list collections: %v", err)
	}
	if len(collections) != 0 {
		t.Fatalf("expected collection delete, got %#v", collections)
	}
	requests, err := store.listAllCollectionRequests(ctx)
	if err != nil {
		t.Fatalf("list requests: %v", err)
	}
	if len(requests) != 0 {
		t.Fatalf("expected cascade request delete, got %#v", requests)
	}
}

var _ profileScanner = (*sql.Row)(nil)

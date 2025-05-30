package services

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"protodesk/pkg/models"
	"protodesk/pkg/models/proto"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func setupTestStore(t *testing.T) (*SQLiteStore, func()) {
	tmpDir, err := os.MkdirTemp("", "protodesk-test-*")
	require.NoError(t, err)

	store, err := NewSQLiteStore(tmpDir)
	require.NoError(t, err)

	cleanup := func() {
		os.RemoveAll(tmpDir)
	}

	return store, cleanup
}

func TestNewSQLiteStore(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "protodesk-test-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	store, err := NewSQLiteStore(tmpDir)
	require.NoError(t, err)
	assert.NotNil(t, store)
	assert.NotNil(t, store.db)

	// Verify database file was created
	dbPath := filepath.Join(tmpDir, "protodesk.db")
	_, err = os.Stat(dbPath)
	assert.NoError(t, err)
}

func TestNewSQLiteStore_Errors(t *testing.T) {
	// Test with invalid directory path
	store, err := NewSQLiteStore("/nonexistent/directory")
	assert.Error(t, err)
	assert.Nil(t, store)
	assert.Contains(t, err.Error(), "failed to connect to database")

	// Test with read-only directory
	tmpDir, err := os.MkdirTemp("", "protodesk-test-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	// Make directory read-only
	require.NoError(t, os.Chmod(tmpDir, 0555))
	defer os.Chmod(tmpDir, 0755) // Restore permissions for cleanup

	store, err = NewSQLiteStore(tmpDir)
	assert.Error(t, err)
	assert.Nil(t, store)
	assert.Contains(t, err.Error(), "failed to connect to database")
}

func TestSQLiteStore_CRUD(t *testing.T) {
	store, cleanup := setupTestStore(t)
	defer cleanup()

	ctx := context.Background()

	// Test Create
	profile := models.NewServerProfile("test-server", "localhost", 50051)
	err := store.Create(ctx, profile)
	require.NoError(t, err)

	// Test Get
	retrieved, err := store.Get(ctx, profile.ID)
	require.NoError(t, err)
	assert.Equal(t, profile.ID, retrieved.ID)
	assert.Equal(t, profile.Name, retrieved.Name)
	assert.Equal(t, profile.Host, retrieved.Host)
	assert.Equal(t, profile.Port, retrieved.Port)
	assert.Equal(t, profile.TLSEnabled, retrieved.TLSEnabled)
	assert.Equal(t, profile.CertificatePath, retrieved.CertificatePath)
	assert.WithinDuration(t, profile.CreatedAt, retrieved.CreatedAt, time.Second)
	assert.WithinDuration(t, profile.UpdatedAt, retrieved.UpdatedAt, time.Second)

	// Test List
	profiles, err := store.List(ctx)
	require.NoError(t, err)
	assert.Len(t, profiles, 1)
	assert.Equal(t, profile.ID, profiles[0].ID)

	// Test Update
	profile.Name = "updated-server"
	profile.Port = 50052
	profile.UpdatedAt = time.Now()
	err = store.Update(ctx, profile)
	require.NoError(t, err)

	updated, err := store.Get(ctx, profile.ID)
	require.NoError(t, err)
	assert.Equal(t, "updated-server", updated.Name)
	assert.Equal(t, 50052, updated.Port)

	// Test Delete
	err = store.Delete(ctx, profile.ID)
	require.NoError(t, err)

	_, err = store.Get(ctx, profile.ID)
	assert.Equal(t, models.ErrProfileNotFound, err)

	profiles, err = store.List(ctx)
	require.NoError(t, err)
	assert.Empty(t, profiles)
}

func TestSQLiteStore_NotFound(t *testing.T) {
	store, cleanup := setupTestStore(t)
	defer cleanup()

	ctx := context.Background()

	// Test Get non-existent profile
	_, err := store.Get(ctx, "non-existent")
	assert.Equal(t, models.ErrProfileNotFound, err)

	// Test Update non-existent profile
	profile := models.NewServerProfile("test", "localhost", 50051)
	profile.ID = "non-existent"
	err = store.Update(ctx, profile)
	assert.Equal(t, models.ErrProfileNotFound, err)

	// Test Delete non-existent profile
	err = store.Delete(ctx, "non-existent")
	assert.Equal(t, models.ErrProfileNotFound, err)
}

func TestSQLiteStore_Validation(t *testing.T) {
	store, cleanup := setupTestStore(t)
	defer cleanup()

	ctx := context.Background()

	// Test Create with invalid profile
	profile := models.NewServerProfile("", "", 0) // Invalid name, host, and port
	err := store.Create(ctx, profile)
	require.Error(t, err)

	// Test Update with invalid profile
	profile = models.NewServerProfile("test", "localhost", 50051)
	err = store.Create(ctx, profile)
	require.NoError(t, err)

	profile.Name = "" // Make it invalid
	err = store.Update(ctx, profile)
	require.Error(t, err)
}

func TestSQLiteStore_ProtoDefinitionCRUD(t *testing.T) {
	store, cleanup := setupTestStore(t)
	defer cleanup()
	ctx := context.Background()

	// Create a proto definition
	profile := models.NewServerProfile("profile-1", "localhost", 50051)
	profile.ID = "profile-1"
	require.NoError(t, store.Create(ctx, profile))
	protoPath := &proto.ProtoPath{ID: "path1", ServerProfileID: "profile-1", Path: "/tmp"}
	require.NoError(t, store.CreateProtoPath(ctx, protoPath))
	def := &proto.ProtoDefinition{
		ID:              "test-proto",
		FilePath:        "/tmp/test.proto",
		Content:         "syntax = \"proto3\";",
		Imports:         []string{"google/protobuf/empty.proto"},
		Services:        []proto.Service{{Name: "TestService", Methods: nil, Description: ""}},
		CreatedAt:       time.Now(),
		UpdatedAt:       time.Now(),
		Description:     "Test proto definition",
		Version:         "1",
		ServerProfileID: "profile-1",
		ProtoPathID:     "path1",
	}

	// Create
	err := store.CreateProtoDefinition(ctx, def)
	require.NoError(t, err)

	// Get
	got, err := store.GetProtoDefinition(ctx, def.ID)
	require.NoError(t, err)
	assert.Equal(t, def.ID, got.ID)
	assert.Equal(t, def.FilePath, got.FilePath)
	assert.Equal(t, def.Content, got.Content)
	assert.Equal(t, def.Imports, got.Imports)
	assert.Equal(t, def.Services[0].Name, got.Services[0].Name)
	assert.Equal(t, def.ServerProfileID, got.ServerProfileID)

	// List
	defs, err := store.ListProtoDefinitions(ctx)
	require.NoError(t, err)
	assert.NotEmpty(t, defs)

	// Update
	def.Description = "Updated description"
	def.UpdatedAt = time.Now()
	err = store.UpdateProtoDefinition(ctx, def)
	require.NoError(t, err)
	got, err = store.GetProtoDefinition(ctx, def.ID)
	require.NoError(t, err)
	assert.Equal(t, "Updated description", got.Description)

	// List by profile
	byProfile, err := store.ListProtoDefinitionsByProfile(ctx, def.ServerProfileID)
	require.NoError(t, err)
	assert.NotEmpty(t, byProfile)
	assert.Equal(t, def.ID, byProfile[0].ID)

	// Delete
	err = store.DeleteProtoDefinition(ctx, def.ID)
	require.NoError(t, err)
	_, err = store.GetProtoDefinition(ctx, def.ID)
	assert.Error(t, err)
}

func TestProtoDefinitionStorage_CRUD_EnumsAndOptions(t *testing.T) {
	store, cleanup := setupTestStore(t)
	defer cleanup()
	ctx := context.Background()

	// Create test proto definition with enums and file options
	profile := models.NewServerProfile("server1", "localhost", 50051)
	profile.ID = "server1"
	require.NoError(t, store.Create(ctx, profile))
	protoPath := &proto.ProtoPath{ID: "path1", ServerProfileID: "server1", Path: "/tmp"}
	require.NoError(t, store.CreateProtoPath(ctx, protoPath))

	pd := &proto.ProtoDefinition{
		ID:              "test1.proto",
		FilePath:        "/tmp/test1.proto",
		Content:         "syntax = \"proto3\";",
		Imports:         []string{"google/protobuf/timestamp.proto"},
		Services:        []proto.Service{{Name: "TestService"}},
		CreatedAt:       time.Now(),
		UpdatedAt:       time.Now(),
		Description:     "Test proto",
		Version:         "1",
		ServerProfileID: "server1",
		ProtoPathID:     "path1",
		LastParsed:      time.Now(),
		Error:           "",
		Enums: []proto.EnumType{{
			Name:        "TestEnum",
			Values:      []proto.EnumValue{{Name: "A", Number: 0}, {Name: "B", Number: 1}},
			Description: "Enum description",
		}},
		FileOptions: `{"java_package":"com.example"}`,
	}

	// Create
	require.NoError(t, store.CreateProtoDefinition(ctx, pd))

	// Read
	got, err := store.GetProtoDefinition(ctx, pd.ID)
	require.NoError(t, err)
	require.Equal(t, pd.ID, got.ID)
	require.Equal(t, pd.FilePath, got.FilePath)
	require.Equal(t, pd.Enums[0].Name, got.Enums[0].Name)
	require.Equal(t, pd.FileOptions, got.FileOptions)

	// Update
	got.Description = "Updated desc"
	got.Enums = append(got.Enums, proto.EnumType{Name: "AnotherEnum"})
	require.NoError(t, store.UpdateProtoDefinition(ctx, got))
	got2, err := store.GetProtoDefinition(ctx, pd.ID)
	require.NoError(t, err)
	require.Equal(t, "Updated desc", got2.Description)
	require.Len(t, got2.Enums, 2)

	// Delete
	require.NoError(t, store.DeleteProtoDefinition(ctx, pd.ID))
	_, err = store.GetProtoDefinition(ctx, pd.ID)
	require.Error(t, err)
}

func TestListProtoDefinitionsByProtoPath(t *testing.T) {
	store, cleanup := setupTestStore(t)
	defer cleanup()
	ctx := context.Background()

	profile := models.NewServerProfile("server1", "localhost", 50051)
	profile.ID = "server1"
	require.NoError(t, store.Create(ctx, profile))
	protoPathA := &proto.ProtoPath{ID: "path1", ServerProfileID: "server1", Path: "/tmp/a"}
	protoPathB := &proto.ProtoPath{ID: "path2", ServerProfileID: "server1", Path: "/tmp/b"}
	require.NoError(t, store.CreateProtoPath(ctx, protoPathA))
	require.NoError(t, store.CreateProtoPath(ctx, protoPathB))

	pd1 := &proto.ProtoDefinition{ID: "a.proto", FilePath: "/a.proto", ProtoPathID: "path1", ServerProfileID: "server1", CreatedAt: time.Now(), UpdatedAt: time.Now()}
	pd2 := &proto.ProtoDefinition{ID: "b.proto", FilePath: "/b.proto", ProtoPathID: "path2", ServerProfileID: "server1", CreatedAt: time.Now(), UpdatedAt: time.Now()}
	pd3 := &proto.ProtoDefinition{ID: "c.proto", FilePath: "/c.proto", ProtoPathID: "path1", ServerProfileID: "server1", CreatedAt: time.Now(), UpdatedAt: time.Now()}
	require.NoError(t, store.CreateProtoDefinition(ctx, pd1))
	require.NoError(t, store.CreateProtoDefinition(ctx, pd2))
	require.NoError(t, store.CreateProtoDefinition(ctx, pd3))

	defsA, err := store.ListProtoDefinitionsByProtoPath(ctx, "path1")
	require.NoError(t, err)
	require.Len(t, defsA, 2)
	defsB, err := store.ListProtoDefinitionsByProtoPath(ctx, "path2")
	require.NoError(t, err)
	require.Len(t, defsB, 1)
}

func TestCascadeDeleteProtoPath(t *testing.T) {
	store, cleanup := setupTestStore(t)
	defer cleanup()
	ctx := context.Background()

	// Create proto path and proto definition
	profile := models.NewServerProfile("serverX", "localhost", 50051)
	profile.ID = "serverX"
	require.NoError(t, store.Create(ctx, profile))
	protoPath := &proto.ProtoPath{ID: "pathX", ServerProfileID: "serverX", Path: "/foo"}
	require.NoError(t, store.CreateProtoPath(ctx, protoPath))
	pd := &proto.ProtoDefinition{ID: "x.proto", FilePath: "/x.proto", ProtoPathID: "pathX", ServerProfileID: "serverX", CreatedAt: time.Now(), UpdatedAt: time.Now()}
	require.NoError(t, store.CreateProtoDefinition(ctx, pd))

	// Delete proto path
	require.NoError(t, store.DeleteProtoPath(ctx, "pathX"))

	// Proto definition should be deleted
	_, err := store.GetProtoDefinition(ctx, "x.proto")
	require.Error(t, err)
}

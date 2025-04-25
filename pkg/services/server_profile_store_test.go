package services

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"protodesk/pkg/models"

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

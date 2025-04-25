package app

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestNewApp(t *testing.T) {
	app := NewApp()
	assert.NotNil(t, app)
}

func TestApp_Startup(t *testing.T) {
	app := NewApp()
	ctx := context.Background()

	// Create temporary directory for test
	tmpDir, err := os.MkdirTemp("", "protodesk-test-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	// Set temporary directory as home directory for test
	t.Setenv("HOME", tmpDir)

	err = app.Startup(ctx)
	require.NoError(t, err)

	// Verify data directory was created
	dataDir := filepath.Join(tmpDir, ".protodesk")
	_, err = os.Stat(dataDir)
	assert.NoError(t, err)
}

func TestApp_ServerProfileOperations(t *testing.T) {
	app := NewApp()
	ctx := context.Background()

	// Setup test environment
	tmpDir, err := os.MkdirTemp("", "protodesk-test-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)
	t.Setenv("HOME", tmpDir)
	require.NoError(t, app.Startup(ctx))

	// Test CreateServerProfile
	profile, err := app.CreateServerProfile("test-server", "localhost", 50051, false, nil)
	require.NoError(t, err)
	assert.NotNil(t, profile)
	assert.NotEmpty(t, profile.ID)
	assert.Equal(t, "test-server", profile.Name)
	assert.Equal(t, "localhost", profile.Host)
	assert.Equal(t, 50051, profile.Port)
	assert.False(t, profile.TLSEnabled)
	assert.Nil(t, profile.CertificatePath)

	// Test GetServerProfile
	retrieved, err := app.GetServerProfile(profile.ID)
	require.NoError(t, err)
	assert.Equal(t, profile.ID, retrieved.ID)
	assert.Equal(t, profile.Name, retrieved.Name)

	// Test ListServerProfiles
	profiles, err := app.ListServerProfiles()
	require.NoError(t, err)
	assert.Len(t, profiles, 1)
	assert.Equal(t, profile.ID, profiles[0].ID)

	// Test UpdateServerProfile
	profile.Name = "updated-server"
	err = app.UpdateServerProfile(profile)
	require.NoError(t, err)

	updated, err := app.GetServerProfile(profile.ID)
	require.NoError(t, err)
	assert.Equal(t, "updated-server", updated.Name)

	// Test DeleteServerProfile
	err = app.DeleteServerProfile(profile.ID)
	require.NoError(t, err)

	profiles, err = app.ListServerProfiles()
	require.NoError(t, err)
	assert.Empty(t, profiles)
}

func TestApp_ServerConnections(t *testing.T) {
	app := NewApp()
	ctx := context.Background()

	// Setup test environment
	tmpDir, err := os.MkdirTemp("", "protodesk-test-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)
	t.Setenv("HOME", tmpDir)
	require.NoError(t, app.Startup(ctx))

	// Create a test profile
	profile, err := app.CreateServerProfile("test-server", "localhost", 50051, false, nil)
	require.NoError(t, err)

	// Test connection operations
	assert.False(t, app.IsServerConnected(profile.ID))

	err = app.ConnectToServer(profile.ID)
	require.NoError(t, err)
	assert.True(t, app.IsServerConnected(profile.ID))

	err = app.DisconnectFromServer(profile.ID)
	require.NoError(t, err)
	assert.False(t, app.IsServerConnected(profile.ID))
}

func TestApp_Shutdown(t *testing.T) {
	app := NewApp()
	ctx := context.Background()

	// Setup test environment
	tmpDir, err := os.MkdirTemp("", "protodesk-test-*")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)
	t.Setenv("HOME", tmpDir)
	require.NoError(t, app.Startup(ctx))

	// Create and connect to a test profile
	profile, err := app.CreateServerProfile("test-server", "localhost", 50051, false, nil)
	require.NoError(t, err)
	require.NoError(t, app.ConnectToServer(profile.ID))

	// Test shutdown
	app.Shutdown(ctx)
	assert.False(t, app.IsServerConnected(profile.ID))
}

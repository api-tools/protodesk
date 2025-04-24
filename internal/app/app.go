package app

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"protodesk/pkg/models"
	"protodesk/pkg/services"
)

// App struct represents the main application
type App struct {
	ctx            context.Context
	profileManager *services.ServerProfileManager
}

// NewApp creates a new App application struct
func NewApp() *App {
	return &App{}
}

// Startup is called when the app starts. The context is saved
// so we can call the runtime methods
func (a *App) Startup(ctx context.Context) error {
	a.ctx = ctx

	// Initialize data directory
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("failed to get user home directory: %w", err)
	}

	dataDir := filepath.Join(homeDir, ".protodesk")
	if err := os.MkdirAll(dataDir, 0755); err != nil {
		return fmt.Errorf("failed to create data directory: %w", err)
	}

	// Initialize server profile store and manager
	store, err := services.NewSQLiteStore(dataDir)
	if err != nil {
		return fmt.Errorf("failed to initialize server profile store: %w", err)
	}

	a.profileManager = services.NewServerProfileManager(store)
	return nil
}

// CreateServerProfile creates a new server profile
func (a *App) CreateServerProfile(name string, host string, port int, enableTLS bool, certPath *string) (*models.ServerProfile, error) {
	profile := models.NewServerProfile(name, host, port)
	profile.TLSEnabled = enableTLS
	profile.CertificatePath = certPath

	if err := profile.Validate(); err != nil {
		return nil, err
	}

	if err := a.profileManager.GetStore().Create(a.ctx, profile); err != nil {
		return nil, fmt.Errorf("failed to create server profile: %w", err)
	}

	return profile, nil
}

// GetServerProfile retrieves a server profile by ID
func (a *App) GetServerProfile(id string) (*models.ServerProfile, error) {
	return a.profileManager.GetStore().Get(a.ctx, id)
}

// ListServerProfiles returns all server profiles
func (a *App) ListServerProfiles() ([]*models.ServerProfile, error) {
	return a.profileManager.GetStore().List(a.ctx)
}

// UpdateServerProfile updates an existing server profile
func (a *App) UpdateServerProfile(profile *models.ServerProfile) error {
	if err := profile.Validate(); err != nil {
		return err
	}
	return a.profileManager.GetStore().Update(a.ctx, profile)
}

// DeleteServerProfile deletes a server profile by ID
func (a *App) DeleteServerProfile(id string) error {
	// Disconnect if connected
	if a.profileManager.IsConnected(id) {
		if err := a.profileManager.Disconnect(a.ctx, id); err != nil {
			return fmt.Errorf("failed to disconnect before deletion: %w", err)
		}
	}
	return a.profileManager.GetStore().Delete(a.ctx, id)
}

// ConnectToServer establishes a connection to a server profile
func (a *App) ConnectToServer(id string) error {
	return a.profileManager.Connect(a.ctx, id)
}

// DisconnectFromServer closes the connection to a server profile
func (a *App) DisconnectFromServer(id string) error {
	return a.profileManager.Disconnect(a.ctx, id)
}

// IsServerConnected checks if a server profile is currently connected
func (a *App) IsServerConnected(id string) bool {
	return a.profileManager.IsConnected(id)
}

// Shutdown handles cleanup when the application exits
func (a *App) Shutdown(ctx context.Context) {
	a.profileManager.DisconnectAll()
}

// Greet returns a greeting for the given name
func (a *App) Greet(name string) string {
	return fmt.Sprintf("Hello %s, It's show time!", name)
}

package services

import (
	"context"
	"fmt"
	"path/filepath"

	"protodesk/pkg/models"

	"github.com/jmoiron/sqlx"
	_ "github.com/mattn/go-sqlite3"
)

// ServerProfileStore defines the interface for server profile storage operations
type ServerProfileStore interface {
	Create(ctx context.Context, profile *models.ServerProfile) error
	Get(ctx context.Context, id string) (*models.ServerProfile, error)
	List(ctx context.Context) ([]*models.ServerProfile, error)
	Update(ctx context.Context, profile *models.ServerProfile) error
	Delete(ctx context.Context, id string) error
}

// SQLiteStore implements ServerProfileStore using SQLite
type SQLiteStore struct {
	db *sqlx.DB
}

// NewSQLiteStore creates a new SQLite-based store
func NewSQLiteStore(dataDir string) (*SQLiteStore, error) {
	dbPath := filepath.Join(dataDir, "protodesk.db")
	db, err := sqlx.Connect("sqlite3", dbPath)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to database: %w", err)
	}

	if err := initializeSchema(db); err != nil {
		return nil, fmt.Errorf("failed to initialize schema: %w", err)
	}

	return &SQLiteStore{db: db}, nil
}

func initializeSchema(db *sqlx.DB) error {
	schema := `
	CREATE TABLE IF NOT EXISTS server_profiles (
		id TEXT PRIMARY KEY,
		name TEXT NOT NULL,
		host TEXT NOT NULL,
		port INTEGER NOT NULL,
		tls_enabled BOOLEAN DEFAULT FALSE,
		certificate_path TEXT,
		created_at DATETIME NOT NULL,
		updated_at DATETIME NOT NULL
	);
	CREATE INDEX IF NOT EXISTS idx_server_profiles_name ON server_profiles(name);
	`
	_, err := db.Exec(schema)
	return err
}

func (s *SQLiteStore) Create(ctx context.Context, profile *models.ServerProfile) error {
	if err := profile.Validate(); err != nil {
		return err
	}

	query := `
		INSERT INTO server_profiles (
			id, name, host, port, tls_enabled, certificate_path, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
	`
	_, err := s.db.ExecContext(ctx, query,
		profile.ID,
		profile.Name,
		profile.Host,
		profile.Port,
		profile.TLSEnabled,
		profile.CertificatePath,
		profile.CreatedAt,
		profile.UpdatedAt,
	)
	return err
}

func (s *SQLiteStore) Get(ctx context.Context, id string) (*models.ServerProfile, error) {
	var profile models.ServerProfile
	query := `SELECT * FROM server_profiles WHERE id = ?`
	err := s.db.GetContext(ctx, &profile, query, id)
	if err != nil {
		return nil, models.ErrProfileNotFound
	}
	return &profile, nil
}

func (s *SQLiteStore) List(ctx context.Context) ([]*models.ServerProfile, error) {
	var profiles []*models.ServerProfile
	query := `SELECT * FROM server_profiles ORDER BY name`
	err := s.db.SelectContext(ctx, &profiles, query)
	if err != nil {
		return nil, err
	}
	return profiles, nil
}

func (s *SQLiteStore) Update(ctx context.Context, profile *models.ServerProfile) error {
	if err := profile.Validate(); err != nil {
		return err
	}

	query := `
		UPDATE server_profiles SET
			name = ?,
			host = ?,
			port = ?,
			tls_enabled = ?,
			certificate_path = ?,
			updated_at = ?
		WHERE id = ?
	`
	result, err := s.db.ExecContext(ctx, query,
		profile.Name,
		profile.Host,
		profile.Port,
		profile.TLSEnabled,
		profile.CertificatePath,
		profile.UpdatedAt,
		profile.ID,
	)
	if err != nil {
		return err
	}

	rows, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return models.ErrProfileNotFound
	}
	return nil
}

func (s *SQLiteStore) Delete(ctx context.Context, id string) error {
	query := `DELETE FROM server_profiles WHERE id = ?`
	result, err := s.db.ExecContext(ctx, query, id)
	if err != nil {
		return err
	}

	rows, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return models.ErrProfileNotFound
	}
	return nil
}

package services

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"time"

	"protodesk/pkg/models"
	"protodesk/pkg/models/proto"

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
	CreateProtoDefinition(ctx context.Context, def *proto.ProtoDefinition) error
	GetProtoDefinition(ctx context.Context, id string) (*proto.ProtoDefinition, error)
	ListProtoDefinitions(ctx context.Context) ([]*proto.ProtoDefinition, error)
	UpdateProtoDefinition(ctx context.Context, def *proto.ProtoDefinition) error
	DeleteProtoDefinition(ctx context.Context, id string) error
	ListProtoDefinitionsByProfile(ctx context.Context, profileID string) ([]*proto.ProtoDefinition, error)
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

	CREATE TABLE IF NOT EXISTS proto_definitions (
		id TEXT PRIMARY KEY,
		file_path TEXT NOT NULL,
		content TEXT NOT NULL,
		imports TEXT,
		services TEXT,
		created_at DATETIME NOT NULL,
		updated_at DATETIME NOT NULL,
		description TEXT,
		version TEXT,
		server_profile_id TEXT,
		FOREIGN KEY(server_profile_id) REFERENCES server_profiles(id) ON DELETE CASCADE
	);
	CREATE INDEX IF NOT EXISTS idx_proto_definitions_profile ON proto_definitions(server_profile_id);
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

// ProtoDefinition CRUD methods
func (s *SQLiteStore) CreateProtoDefinition(ctx context.Context, def *proto.ProtoDefinition) error {
	importsJSON, err := json.Marshal(def.Imports)
	if err != nil {
		return err
	}
	servicesJSON, err := json.Marshal(def.Services)
	if err != nil {
		return err
	}
	query := `
		INSERT INTO proto_definitions (
			id, file_path, content, imports, services, created_at, updated_at, description, version, server_profile_id
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`
	_, err = s.db.ExecContext(ctx, query,
		def.ID,
		def.FilePath,
		def.Content,
		string(importsJSON),
		string(servicesJSON),
		def.CreatedAt,
		def.UpdatedAt,
		def.Description,
		def.Version,
		def.ServerProfileID,
	)
	return err
}

func (s *SQLiteStore) GetProtoDefinition(ctx context.Context, id string) (*proto.ProtoDefinition, error) {
	var row struct {
		ID              string `db:"id"`
		FilePath        string `db:"file_path"`
		Content         string `db:"content"`
		Imports         string `db:"imports"`
		Services        string `db:"services"`
		CreatedAt       string `db:"created_at"`
		UpdatedAt       string `db:"updated_at"`
		Description     string `db:"description"`
		Version         string `db:"version"`
		ServerProfileID string `db:"server_profile_id"`
	}
	query := `SELECT * FROM proto_definitions WHERE id = ?`
	err := s.db.GetContext(ctx, &row, query, id)
	if err != nil {
		return nil, err
	}
	var imports []string
	_ = json.Unmarshal([]byte(row.Imports), &imports)
	var services []proto.Service
	_ = json.Unmarshal([]byte(row.Services), &services)
	createdAt, _ := time.Parse(time.RFC3339, row.CreatedAt)
	updatedAt, _ := time.Parse(time.RFC3339, row.UpdatedAt)
	return &proto.ProtoDefinition{
		ID:              row.ID,
		FilePath:        row.FilePath,
		Content:         row.Content,
		Imports:         imports,
		Services:        services,
		CreatedAt:       createdAt,
		UpdatedAt:       updatedAt,
		Description:     row.Description,
		Version:         row.Version,
		ServerProfileID: row.ServerProfileID,
	}, nil
}

func (s *SQLiteStore) ListProtoDefinitions(ctx context.Context) ([]*proto.ProtoDefinition, error) {
	var rows []struct {
		ID              string `db:"id"`
		FilePath        string `db:"file_path"`
		Content         string `db:"content"`
		Imports         string `db:"imports"`
		Services        string `db:"services"`
		CreatedAt       string `db:"created_at"`
		UpdatedAt       string `db:"updated_at"`
		Description     string `db:"description"`
		Version         string `db:"version"`
		ServerProfileID string `db:"server_profile_id"`
	}
	query := `SELECT * FROM proto_definitions`
	err := s.db.SelectContext(ctx, &rows, query)
	if err != nil {
		return nil, err
	}
	var defs []*proto.ProtoDefinition
	for _, row := range rows {
		var imports []string
		_ = json.Unmarshal([]byte(row.Imports), &imports)
		var services []proto.Service
		_ = json.Unmarshal([]byte(row.Services), &services)
		createdAt, _ := time.Parse(time.RFC3339, row.CreatedAt)
		updatedAt, _ := time.Parse(time.RFC3339, row.UpdatedAt)
		defs = append(defs, &proto.ProtoDefinition{
			ID:              row.ID,
			FilePath:        row.FilePath,
			Content:         row.Content,
			Imports:         imports,
			Services:        services,
			CreatedAt:       createdAt,
			UpdatedAt:       updatedAt,
			Description:     row.Description,
			Version:         row.Version,
			ServerProfileID: row.ServerProfileID,
		})
	}
	return defs, nil
}

func (s *SQLiteStore) UpdateProtoDefinition(ctx context.Context, def *proto.ProtoDefinition) error {
	importsJSON, err := json.Marshal(def.Imports)
	if err != nil {
		return err
	}
	servicesJSON, err := json.Marshal(def.Services)
	if err != nil {
		return err
	}
	query := `
		UPDATE proto_definitions SET
			file_path = ?,
			content = ?,
			imports = ?,
			services = ?,
			updated_at = ?,
			description = ?,
			version = ?,
			server_profile_id = ?
		WHERE id = ?
	`
	result, err := s.db.ExecContext(ctx, query,
		def.FilePath,
		def.Content,
		string(importsJSON),
		string(servicesJSON),
		def.UpdatedAt,
		def.Description,
		def.Version,
		def.ServerProfileID,
		def.ID,
	)
	if err != nil {
		return err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return fmt.Errorf("proto definition not found")
	}
	return nil
}

func (s *SQLiteStore) DeleteProtoDefinition(ctx context.Context, id string) error {
	query := `DELETE FROM proto_definitions WHERE id = ?`
	result, err := s.db.ExecContext(ctx, query, id)
	if err != nil {
		return err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return fmt.Errorf("proto definition not found")
	}
	return nil
}

func (s *SQLiteStore) ListProtoDefinitionsByProfile(ctx context.Context, profileID string) ([]*proto.ProtoDefinition, error) {
	var rows []struct {
		ID              string `db:"id"`
		FilePath        string `db:"file_path"`
		Content         string `db:"content"`
		Imports         string `db:"imports"`
		Services        string `db:"services"`
		CreatedAt       string `db:"created_at"`
		UpdatedAt       string `db:"updated_at"`
		Description     string `db:"description"`
		Version         string `db:"version"`
		ServerProfileID string `db:"server_profile_id"`
	}
	query := `SELECT * FROM proto_definitions WHERE server_profile_id = ?`
	err := s.db.SelectContext(ctx, &rows, query, profileID)
	if err != nil {
		return nil, err
	}
	var defs []*proto.ProtoDefinition
	for _, row := range rows {
		var imports []string
		_ = json.Unmarshal([]byte(row.Imports), &imports)
		var services []proto.Service
		_ = json.Unmarshal([]byte(row.Services), &services)
		createdAt, _ := time.Parse(time.RFC3339, row.CreatedAt)
		updatedAt, _ := time.Parse(time.RFC3339, row.UpdatedAt)
		defs = append(defs, &proto.ProtoDefinition{
			ID:              row.ID,
			FilePath:        row.FilePath,
			Content:         row.Content,
			Imports:         imports,
			Services:        services,
			CreatedAt:       createdAt,
			UpdatedAt:       updatedAt,
			Description:     row.Description,
			Version:         row.Version,
			ServerProfileID: row.ServerProfileID,
		})
	}
	return defs, nil
}

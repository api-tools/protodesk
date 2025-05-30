package services

import (
	"context"
	"database/sql"
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

	// Add proto path CRUD methods
	CreateProtoPath(ctx context.Context, path *proto.ProtoPath) error
	GetProtoPath(ctx context.Context, id string) (*proto.ProtoPath, error)
	UpdateProtoPath(ctx context.Context, path *proto.ProtoPath) error
	ListProtoPathsByServer(ctx context.Context, serverID string) ([]*proto.ProtoPath, error)
	DeleteProtoPath(ctx context.Context, id string) error

	// Add new methods
	ListProtoDefinitionsByProtoPath(ctx context.Context, protoPathID string) ([]*proto.ProtoDefinition, error)

	// Add per-request headers CRUD methods
	UpsertPerRequestHeaders(ctx context.Context, h *models.PerRequestHeaders) error
	GetPerRequestHeaders(ctx context.Context, serverProfileID, serviceName, methodName string) (*models.PerRequestHeaders, error)
	DeletePerRequestHeaders(ctx context.Context, serverProfileID, serviceName, methodName string) error
}

// ProtoPath represents a proto folder path linked to a server
type ProtoPath struct {
	ID              string
	ServerProfileID string
	Path            string
	Hash            string
	LastScanned     string
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
	// Enable foreign key enforcement
	_, _ = db.Exec("PRAGMA foreign_keys = ON;")

	if err := initializeSchema(db); err != nil {
		return nil, fmt.Errorf("failed to initialize schema: %w", err)
	}

	// Run migrations
	if err := migrateLastScannedColumn(db); err != nil {
		return nil, fmt.Errorf("failed to run migrations: %w", err)
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
		use_reflection BOOLEAN DEFAULT FALSE,
		created_at DATETIME NOT NULL,
		updated_at DATETIME NOT NULL,
		headers_json TEXT DEFAULT '[]'
	);
	CREATE INDEX IF NOT EXISTS idx_server_profiles_name ON server_profiles(name);

	CREATE TABLE IF NOT EXISTS proto_paths (
		id TEXT PRIMARY KEY,
		server_profile_id TEXT NOT NULL,
		path TEXT NOT NULL,
		hash TEXT,
		last_scanned DATETIME,
		UNIQUE(server_profile_id, path),
		FOREIGN KEY(server_profile_id) REFERENCES server_profiles(id) ON DELETE CASCADE
	);
	CREATE INDEX IF NOT EXISTS idx_proto_paths_profile ON proto_paths(server_profile_id);

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
		proto_path_id TEXT,
		last_parsed DATETIME,
		error TEXT,
		enums TEXT,
		file_options TEXT,
		FOREIGN KEY(server_profile_id) REFERENCES server_profiles(id) ON DELETE CASCADE,
		FOREIGN KEY(proto_path_id) REFERENCES proto_paths(id) ON DELETE CASCADE
	);
	CREATE INDEX IF NOT EXISTS idx_proto_definitions_profile ON proto_definitions(server_profile_id);
	CREATE INDEX IF NOT EXISTS idx_proto_definitions_path ON proto_definitions(proto_path_id);

	CREATE TABLE IF NOT EXISTS per_request_headers (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		server_profile_id TEXT NOT NULL,
		service_name TEXT NOT NULL,
		method_name TEXT NOT NULL,
		headers_json TEXT NOT NULL DEFAULT '[]',
		updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		UNIQUE(server_profile_id, service_name, method_name),
		FOREIGN KEY(server_profile_id) REFERENCES server_profiles(id) ON DELETE CASCADE
	);
	CREATE INDEX IF NOT EXISTS idx_per_request_headers_profile ON per_request_headers(server_profile_id);
	`
	_, err := db.Exec(schema)
	return err
}

// migrateLastScannedColumn updates the last_scanned column type from TEXT to DATETIME
func migrateLastScannedColumn(db *sqlx.DB) error {
	// Check if the column exists and is TEXT type
	var columnType string
	err := db.Get(&columnType, `
		SELECT type FROM pragma_table_info('proto_paths') 
		WHERE name = 'last_scanned'
	`)
	if err != nil {
		if err == sql.ErrNoRows {
			// Column doesn't exist, no need to migrate
			return nil
		}
		return fmt.Errorf("failed to check column type: %w", err)
	}

	if columnType == "TEXT" {
		// Create a temporary table with the correct schema
		_, err = db.Exec(`
			CREATE TABLE proto_paths_new (
				id TEXT PRIMARY KEY,
				server_profile_id TEXT NOT NULL,
				path TEXT NOT NULL,
				hash TEXT,
				last_scanned DATETIME,
				UNIQUE(server_profile_id, path),
				FOREIGN KEY(server_profile_id) REFERENCES server_profiles(id) ON DELETE CASCADE
			)
		`)
		if err != nil {
			return fmt.Errorf("failed to create temporary table: %w", err)
		}

		// Copy data, converting TEXT timestamps to DATETIME
		_, err = db.Exec(`
			INSERT INTO proto_paths_new (id, server_profile_id, path, hash, last_scanned)
			SELECT 
				id, 
				server_profile_id, 
				path, 
				hash,
				CASE 
					WHEN last_scanned IS NULL THEN NULL
					WHEN last_scanned = '' THEN NULL
					ELSE datetime(last_scanned)
				END as last_scanned
			FROM proto_paths
		`)
		if err != nil {
			return fmt.Errorf("failed to copy data: %w", err)
		}

		// Drop the old table
		_, err = db.Exec(`DROP TABLE proto_paths`)
		if err != nil {
			return fmt.Errorf("failed to drop old table: %w", err)
		}

		// Rename the new table
		_, err = db.Exec(`ALTER TABLE proto_paths_new RENAME TO proto_paths`)
		if err != nil {
			return fmt.Errorf("failed to rename new table: %w", err)
		}

		// Recreate the index
		_, err = db.Exec(`CREATE INDEX IF NOT EXISTS idx_proto_paths_profile ON proto_paths(server_profile_id)`)
		if err != nil {
			return fmt.Errorf("failed to recreate index: %w", err)
		}
	}

	return nil
}

func (s *SQLiteStore) Create(ctx context.Context, profile *models.ServerProfile) error {
	if err := profile.Validate(); err != nil {
		return err
	}

	// Marshal headers to JSON
	data, err := json.Marshal(profile.Headers)
	if err != nil {
		return err
	}
	profile.HeadersJSON = string(data)

	query := `
		INSERT INTO server_profiles (
			id, name, host, port, tls_enabled, certificate_path, use_reflection, created_at, updated_at, headers_json
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`
	_, err = s.db.ExecContext(ctx, query,
		profile.ID,
		profile.Name,
		profile.Host,
		profile.Port,
		profile.TLSEnabled,
		profile.CertificatePath,
		profile.UseReflection,
		profile.CreatedAt,
		profile.UpdatedAt,
		profile.HeadersJSON,
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
	// Unmarshal headers_json into Headers
	if profile.HeadersJSON != "" {
		_ = json.Unmarshal([]byte(profile.HeadersJSON), &profile.Headers)
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
	// Unmarshal headers_json into Headers for each profile
	for _, profile := range profiles {
		if profile.HeadersJSON != "" {
			_ = json.Unmarshal([]byte(profile.HeadersJSON), &profile.Headers)
		}
	}
	return profiles, nil
}

func (s *SQLiteStore) Update(ctx context.Context, profile *models.ServerProfile) error {
	if err := profile.Validate(); err != nil {
		return err
	}

	// Marshal headers to JSON
	data, err := json.Marshal(profile.Headers)
	if err != nil {
		return err
	}
	profile.HeadersJSON = string(data)

	query := `
		UPDATE server_profiles SET
			name = ?,
			host = ?,
			port = ?,
			tls_enabled = ?,
			certificate_path = ?,
			use_reflection = ?,
			updated_at = ?,
			headers_json = ?
		WHERE id = ?
	`
	result, err := s.db.ExecContext(ctx, query,
		profile.Name,
		profile.Host,
		profile.Port,
		profile.TLSEnabled,
		profile.CertificatePath,
		profile.UseReflection,
		profile.UpdatedAt,
		profile.HeadersJSON,
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
	fmt.Printf("[DEBUG] Method: CreateProtoDefinition - Starting for file: %s\n", def.FilePath)

	// Start a transaction
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer tx.Rollback()

	// Marshal imports, services, and enums to JSON
	importsJSON, err := json.Marshal(def.Imports)
	if err != nil {
		return fmt.Errorf("failed to marshal imports: %w", err)
	}

	servicesJSON, err := json.Marshal(def.Services)
	if err != nil {
		return fmt.Errorf("failed to marshal services: %w", err)
	}

	enumsJSON, err := json.Marshal(def.Enums)
	if err != nil {
		return fmt.Errorf("failed to marshal enums: %w", err)
	}

	// Insert the proto definition
	_, err = tx.ExecContext(ctx, `
		INSERT INTO proto_definitions (
			id, file_path, content, imports, services, enums,
			created_at, updated_at, description, server_profile_id, proto_path_id
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`,
		def.ID,
		def.FilePath,
		def.Content,
		string(importsJSON),
		string(servicesJSON),
		string(enumsJSON),
		def.CreatedAt,
		def.UpdatedAt,
		sql.NullString{String: def.Description, Valid: def.Description != ""},
		def.ServerProfileID,
		def.ProtoPathID,
	)
	if err != nil {
		return fmt.Errorf("failed to insert proto definition: %w", err)
	}

	// Commit the transaction
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("failed to commit transaction: %w", err)
	}

	fmt.Printf("[DEBUG] Method: CreateProtoDefinition - Successfully created definition for %s\n", def.FilePath)
	return nil
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
		ProtoPathID     string `db:"proto_path_id"`
		LastParsed      string `db:"last_parsed"`
		Error           string `db:"error"`
		Enums           string `db:"enums"`
		FileOptions     string `db:"file_options"`
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
	var enums []proto.EnumType
	_ = json.Unmarshal([]byte(row.Enums), &enums)
	createdAt, _ := time.Parse(time.RFC3339, row.CreatedAt)
	updatedAt, _ := time.Parse(time.RFC3339, row.UpdatedAt)
	lastParsed, _ := time.Parse(time.RFC3339, row.LastParsed)
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
		ProtoPathID:     row.ProtoPathID,
		LastParsed:      lastParsed,
		Error:           row.Error,
		Enums:           enums,
		FileOptions:     row.FileOptions,
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
		ProtoPathID     string `db:"proto_path_id"`
		LastParsed      string `db:"last_parsed"`
		Error           string `db:"error"`
		Enums           string `db:"enums"`
		FileOptions     string `db:"file_options"`
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
		var enums []proto.EnumType
		_ = json.Unmarshal([]byte(row.Enums), &enums)
		createdAt, _ := time.Parse(time.RFC3339, row.CreatedAt)
		updatedAt, _ := time.Parse(time.RFC3339, row.UpdatedAt)
		lastParsed, _ := time.Parse(time.RFC3339, row.LastParsed)
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
			ProtoPathID:     row.ProtoPathID,
			LastParsed:      lastParsed,
			Error:           row.Error,
			Enums:           enums,
			FileOptions:     row.FileOptions,
		})
	}
	return defs, nil
}

func (s *SQLiteStore) UpdateProtoDefinition(ctx context.Context, def *proto.ProtoDefinition) error {
	fmt.Printf("[DEBUG] Method: UpdateProtoDefinition - Starting for file: %s\n", def.FilePath)

	// Start a transaction
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer tx.Rollback()

	// Marshal imports, services, and enums to JSON
	importsJSON, err := json.Marshal(def.Imports)
	if err != nil {
		return fmt.Errorf("failed to marshal imports: %w", err)
	}

	servicesJSON, err := json.Marshal(def.Services)
	if err != nil {
		return fmt.Errorf("failed to marshal services: %w", err)
	}

	enumsJSON, err := json.Marshal(def.Enums)
	if err != nil {
		return fmt.Errorf("failed to marshal enums: %w", err)
	}

	// Update the proto definition
	_, err = tx.ExecContext(ctx, `
		UPDATE proto_definitions
		SET file_path = ?, content = ?, imports = ?, services = ?, enums = ?,
			updated_at = ?, description = ?, server_profile_id = ?, proto_path_id = ?
		WHERE id = ?
	`,
		def.FilePath,
		def.Content,
		string(importsJSON),
		string(servicesJSON),
		string(enumsJSON),
		def.UpdatedAt,
		sql.NullString{String: def.Description, Valid: def.Description != ""},
		def.ServerProfileID,
		def.ProtoPathID,
		def.ID,
	)
	if err != nil {
		return fmt.Errorf("failed to update proto definition: %w", err)
	}

	// Commit the transaction
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("failed to commit transaction: %w", err)
	}

	fmt.Printf("[DEBUG] Method: UpdateProtoDefinition - Successfully updated definition for %s\n", def.FilePath)
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
	fmt.Printf("[DEBUG] Method: ListProtoDefinitionsByProfile - Starting for profile: %s\n", profileID)

	rows, err := s.db.QueryContext(ctx, `
		SELECT id, file_path, content, imports, services, enums, created_at, updated_at, description, server_profile_id, proto_path_id
		FROM proto_definitions
		WHERE server_profile_id = ?
	`, profileID)
	if err != nil {
		return nil, fmt.Errorf("failed to query proto definitions: %w", err)
	}
	defer rows.Close()

	var definitions []*proto.ProtoDefinition
	for rows.Next() {
		var def proto.ProtoDefinition
		var description sql.NullString
		var importsJSON, servicesJSON, enumsJSON string

		err := rows.Scan(
			&def.ID,
			&def.FilePath,
			&def.Content,
			&importsJSON,
			&servicesJSON,
			&enumsJSON,
			&def.CreatedAt,
			&def.UpdatedAt,
			&description,
			&def.ServerProfileID,
			&def.ProtoPathID,
		)
		if err != nil {
			return nil, fmt.Errorf("failed to scan proto definition: %w", err)
		}

		// Unmarshal JSON fields
		if err := json.Unmarshal([]byte(importsJSON), &def.Imports); err != nil {
			return nil, fmt.Errorf("failed to unmarshal imports: %w", err)
		}
		if err := json.Unmarshal([]byte(servicesJSON), &def.Services); err != nil {
			return nil, fmt.Errorf("failed to unmarshal services: %w", err)
		}
		if err := json.Unmarshal([]byte(enumsJSON), &def.Enums); err != nil {
			return nil, fmt.Errorf("failed to unmarshal enums: %w", err)
		}

		if description.Valid {
			def.Description = description.String
		}

		definitions = append(definitions, &def)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("error iterating proto definition rows: %w", err)
	}

	fmt.Printf("[DEBUG] Method: ListProtoDefinitionsByProfile - Found %d definitions\n", len(definitions))
	return definitions, nil
}

// ListProtoDefinitionsByProtoPath lists proto definitions for a given proto path
func (s *SQLiteStore) ListProtoDefinitionsByProtoPath(ctx context.Context, protoPathID string) ([]*proto.ProtoDefinition, error) {
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
		ProtoPathID     string `db:"proto_path_id"`
		LastParsed      string `db:"last_parsed"`
		Error           string `db:"error"`
		Enums           string `db:"enums"`
		FileOptions     string `db:"file_options"`
	}
	query := `SELECT * FROM proto_definitions WHERE proto_path_id = ?`
	err := s.db.SelectContext(ctx, &rows, query, protoPathID)
	if err != nil {
		return nil, err
	}
	var defs []*proto.ProtoDefinition
	for _, row := range rows {
		var imports []string
		_ = json.Unmarshal([]byte(row.Imports), &imports)
		var services []proto.Service
		_ = json.Unmarshal([]byte(row.Services), &services)
		var enums []proto.EnumType
		_ = json.Unmarshal([]byte(row.Enums), &enums)
		createdAt, _ := time.Parse(time.RFC3339, row.CreatedAt)
		updatedAt, _ := time.Parse(time.RFC3339, row.UpdatedAt)
		lastParsed, _ := time.Parse(time.RFC3339, row.LastParsed)
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
			ProtoPathID:     row.ProtoPathID,
			LastParsed:      lastParsed,
			Error:           row.Error,
			Enums:           enums,
			FileOptions:     row.FileOptions,
		})
	}
	return defs, nil
}

func (s *SQLiteStore) CreateProtoPath(ctx context.Context, path *proto.ProtoPath) error {
	fmt.Printf("[DEBUG] SQLiteStore.CreateProtoPath called with ID: %s, ServerProfileID: %s, Path: %s\n", path.ID, path.ServerProfileID, path.Path)
	query := `INSERT INTO proto_paths (id, server_profile_id, path, hash, last_scanned) VALUES (?, ?, ?, ?, ?)`
	_, err := s.db.ExecContext(ctx, query, path.ID, path.ServerProfileID, path.Path, path.Hash, path.LastScanned)
	if err != nil {
		fmt.Printf("[ERROR] Failed to insert proto path: %v\n", err)
		return err
	}
	fmt.Printf("[DEBUG] Successfully inserted proto path into database\n")
	return nil
}

func (s *SQLiteStore) GetProtoPath(ctx context.Context, id string) (*proto.ProtoPath, error) {
	var row struct {
		ID              string    `db:"id"`
		ServerProfileID string    `db:"server_profile_id"`
		Path            string    `db:"path"`
		Hash            string    `db:"hash"`
		LastScanned     time.Time `db:"last_scanned"`
	}
	query := `SELECT * FROM proto_paths WHERE id = ?`
	err := s.db.GetContext(ctx, &row, query, id)
	if err != nil {
		return nil, err
	}
	return &proto.ProtoPath{
		ID:              row.ID,
		ServerProfileID: row.ServerProfileID,
		Path:            row.Path,
		Hash:            row.Hash,
		LastScanned:     row.LastScanned,
	}, nil
}

func (s *SQLiteStore) UpdateProtoPath(ctx context.Context, path *proto.ProtoPath) error {
	query := `
	UPDATE proto_paths SET
		path = ?,
		hash = ?,
		last_scanned = ?
	WHERE id = ?
	`
	_, err := s.db.ExecContext(ctx, query, path.Path, path.Hash, path.LastScanned, path.ID)
	return err
}

func (s *SQLiteStore) ListProtoPathsByServer(ctx context.Context, serverID string) ([]*proto.ProtoPath, error) {
	var rows []struct {
		ID              string    `db:"id"`
		ServerProfileID string    `db:"server_profile_id"`
		Path            string    `db:"path"`
		Hash            string    `db:"hash"`
		LastScanned     time.Time `db:"last_scanned"`
	}
	query := `SELECT * FROM proto_paths WHERE server_profile_id = ?`
	err := s.db.SelectContext(ctx, &rows, query, serverID)
	if err != nil {
		return nil, err
	}
	var paths []*proto.ProtoPath
	for _, row := range rows {
		paths = append(paths, &proto.ProtoPath{
			ID:              row.ID,
			ServerProfileID: row.ServerProfileID,
			Path:            row.Path,
			Hash:            row.Hash,
			LastScanned:     row.LastScanned,
		})
	}
	return paths, nil
}

func (s *SQLiteStore) DeleteProtoPath(ctx context.Context, id string) error {
	query := `DELETE FROM proto_paths WHERE id = ?`
	_, err := s.db.ExecContext(ctx, query, id)
	return err
}

// Upsert per-request headers
func (s *SQLiteStore) UpsertPerRequestHeaders(ctx context.Context, h *models.PerRequestHeaders) error {
	query := `
	INSERT INTO per_request_headers (server_profile_id, service_name, method_name, headers_json, updated_at)
	VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
	ON CONFLICT(server_profile_id, service_name, method_name)
	DO UPDATE SET headers_json=excluded.headers_json, updated_at=CURRENT_TIMESTAMP
	`
	_, err := s.db.ExecContext(ctx, query, h.ServerProfileID, h.ServiceName, h.MethodName, h.HeadersJSON)
	return err
}

// Get per-request headers for a method
func (s *SQLiteStore) GetPerRequestHeaders(ctx context.Context, serverProfileID, serviceName, methodName string) (*models.PerRequestHeaders, error) {
	var h models.PerRequestHeaders
	query := `
	SELECT * FROM per_request_headers
	WHERE server_profile_id = ? AND service_name = ? AND method_name = ?
	LIMIT 1
	`
	err := s.db.GetContext(ctx, &h, query, serverProfileID, serviceName, methodName)
	if err != nil {
		return nil, err
	}
	return &h, nil
}

// Delete per-request headers for a method
func (s *SQLiteStore) DeletePerRequestHeaders(ctx context.Context, serverProfileID, serviceName, methodName string) error {
	query := `
	DELETE FROM per_request_headers
	WHERE server_profile_id = ? AND service_name = ? AND method_name = ?
	`
	_, err := s.db.ExecContext(ctx, query, serverProfileID, serviceName, methodName)
	return err
}

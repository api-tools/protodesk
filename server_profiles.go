package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/google/uuid"
	_ "modernc.org/sqlite"
)

const localWorkspaceID = "local"

type serverProfileStore struct {
	db *sql.DB
}

func newServerProfileStore(databasePath string) (*serverProfileStore, error) {
	if err := os.MkdirAll(filepath.Dir(databasePath), 0o755); err != nil {
		return nil, fmt.Errorf("create app data directory: %w", err)
	}

	db, err := sql.Open("sqlite", databasePath)
	if err != nil {
		return nil, fmt.Errorf("open sqlite database: %w", err)
	}
	db.SetMaxOpenConns(1)

	store := &serverProfileStore{db: db}
	if err := store.init(context.Background()); err != nil {
		_ = db.Close()
		return nil, err
	}
	return store, nil
}

func defaultDatabasePath() (string, error) {
	configDir, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("resolve user config directory: %w", err)
	}
	return filepath.Join(configDir, "ProtoDesk", "protodesk.sqlite"), nil
}

func (s *serverProfileStore) close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
}

func (s *serverProfileStore) init(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS servers (
			workspace_id TEXT NOT NULL,
			id TEXT NOT NULL,
			name TEXT NOT NULL,
			address TEXT NOT NULL,
			tls_enabled INTEGER NOT NULL,
			reflection_enabled INTEGER NOT NULL,
			proto_files_json TEXT NOT NULL,
			proto_folders_json TEXT NOT NULL,
			metadata_json TEXT NOT NULL,
			created_at TEXT NOT NULL,
			updated_at TEXT NOT NULL,
			PRIMARY KEY (workspace_id, id)
		);
		CREATE INDEX IF NOT EXISTS idx_servers_workspace_updated
			ON servers (workspace_id, updated_at, name);
		CREATE TABLE IF NOT EXISTS history_items (
			workspace_id TEXT NOT NULL,
			id TEXT NOT NULL,
			server_id TEXT NOT NULL,
			server_name TEXT NOT NULL,
			server_address TEXT NOT NULL,
			service_name TEXT NOT NULL,
			method_name TEXT NOT NULL,
			full_method TEXT NOT NULL,
			request_json TEXT NOT NULL,
			request_metadata_json TEXT NOT NULL,
			response_json TEXT NOT NULL,
			status_code TEXT NOT NULL,
			status_message TEXT NOT NULL,
			duration_ms INTEGER NOT NULL,
			error TEXT NOT NULL,
			created_at TEXT NOT NULL,
			PRIMARY KEY (workspace_id, id)
		);
		CREATE INDEX IF NOT EXISTS idx_history_workspace_created
			ON history_items (workspace_id, created_at DESC);
		CREATE TABLE IF NOT EXISTS collections (
			workspace_id TEXT NOT NULL,
			id TEXT NOT NULL,
			name TEXT NOT NULL,
			description TEXT NOT NULL,
			created_at TEXT NOT NULL,
			updated_at TEXT NOT NULL,
			PRIMARY KEY (workspace_id, id)
		);
		CREATE INDEX IF NOT EXISTS idx_collections_workspace_updated
			ON collections (workspace_id, updated_at DESC, name);
		CREATE TABLE IF NOT EXISTS collection_requests (
			workspace_id TEXT NOT NULL,
			id TEXT NOT NULL,
			collection_id TEXT NOT NULL,
			name TEXT NOT NULL,
			server_id TEXT NOT NULL,
			server_name TEXT NOT NULL,
			server_address TEXT NOT NULL,
			service_name TEXT NOT NULL,
			method_name TEXT NOT NULL,
			full_method TEXT NOT NULL,
			request_json TEXT NOT NULL,
			request_metadata_json TEXT NOT NULL,
			created_at TEXT NOT NULL,
			updated_at TEXT NOT NULL,
			PRIMARY KEY (workspace_id, id),
			FOREIGN KEY (workspace_id, collection_id)
				REFERENCES collections(workspace_id, id)
				ON DELETE CASCADE
		);
		CREATE INDEX IF NOT EXISTS idx_collection_requests_collection_updated
			ON collection_requests (workspace_id, collection_id, updated_at DESC, name);
	`)
	if err != nil {
		return fmt.Errorf("initialize server profile schema: %w", err)
	}
	return nil
}

func (s *serverProfileStore) listCollections(ctx context.Context) ([]Collection, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT workspace_id, id, name, description, created_at, updated_at
		FROM collections
		WHERE workspace_id = ?
		ORDER BY updated_at DESC, name ASC
	`, localWorkspaceID)
	if err != nil {
		return nil, fmt.Errorf("list collections: %w", err)
	}
	defer rows.Close()

	var collections []Collection
	for rows.Next() {
		collection, err := scanCollection(rows)
		if err != nil {
			return nil, err
		}
		collections = append(collections, collection)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read collections: %w", err)
	}

	requests, err := s.listAllCollectionRequests(ctx)
	if err != nil {
		return nil, err
	}
	for index := range collections {
		collections[index].Requests = requests[collections[index].ID]
	}
	return collections, nil
}

func (s *serverProfileStore) createCollection(ctx context.Context, request SaveCollectionRequest) (Collection, error) {
	collection := normalizeCollection(Collection{
		WorkspaceID: localWorkspaceID,
		ID:          uuid.NewString(),
		Name:        request.Name,
		Description: request.Description,
		CreatedAt:   time.Now().UTC().Format(time.RFC3339Nano),
	})
	collection.UpdatedAt = collection.CreatedAt
	if err := validateCollection(collection); err != nil {
		return Collection{}, err
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO collections (workspace_id, id, name, description, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?)
	`, collection.WorkspaceID, collection.ID, collection.Name, collection.Description, collection.CreatedAt, collection.UpdatedAt)
	if err != nil {
		return Collection{}, fmt.Errorf("create collection: %w", err)
	}
	return collection, nil
}

func (s *serverProfileStore) updateCollection(ctx context.Context, id string, request SaveCollectionRequest) (Collection, error) {
	id = strings.TrimSpace(id)
	if id == "" {
		return Collection{}, errors.New("collection id is required")
	}
	collection := normalizeCollection(Collection{
		WorkspaceID: localWorkspaceID,
		ID:          id,
		Name:        request.Name,
		Description: request.Description,
		UpdatedAt:   time.Now().UTC().Format(time.RFC3339Nano),
	})
	if err := validateCollection(collection); err != nil {
		return Collection{}, err
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE collections
		SET name = ?, description = ?, updated_at = ?
		WHERE workspace_id = ? AND id = ?
	`, collection.Name, collection.Description, collection.UpdatedAt, localWorkspaceID, id)
	if err != nil {
		return Collection{}, fmt.Errorf("update collection: %w", err)
	}
	rowsAffected, err := result.RowsAffected()
	if err != nil {
		return Collection{}, fmt.Errorf("check updated collection: %w", err)
	}
	if rowsAffected == 0 {
		return Collection{}, fmt.Errorf("collection %q not found", id)
	}
	row := s.db.QueryRowContext(ctx, `
		SELECT workspace_id, id, name, description, created_at, updated_at
		FROM collections WHERE workspace_id = ? AND id = ?
	`, localWorkspaceID, id)
	return scanCollection(row)
}

func (s *serverProfileStore) deleteCollection(ctx context.Context, id string) error {
	id = strings.TrimSpace(id)
	if id == "" {
		return errors.New("collection id is required")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin delete collection: %w", err)
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `DELETE FROM collection_requests WHERE workspace_id = ? AND collection_id = ?`, localWorkspaceID, id); err != nil {
		return fmt.Errorf("delete collection requests: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM collections WHERE workspace_id = ? AND id = ?`, localWorkspaceID, id); err != nil {
		return fmt.Errorf("delete collection: %w", err)
	}
	return tx.Commit()
}

func (s *serverProfileStore) createCollectionRequest(ctx context.Context, request SaveCollectionRequestItemRequest) (CollectionRequest, error) {
	item := normalizeCollectionRequest(CollectionRequest{
		WorkspaceID:         localWorkspaceID,
		ID:                  uuid.NewString(),
		CollectionID:        request.CollectionID,
		Name:                request.Name,
		ServerID:            request.ServerID,
		ServerName:          request.ServerName,
		ServerAddress:       request.ServerAddress,
		ServiceName:         request.ServiceName,
		MethodName:          request.MethodName,
		FullMethod:          request.FullMethod,
		RequestJSON:         request.RequestJSON,
		RequestMetadataJSON: request.RequestMetadataJSON,
		CreatedAt:           time.Now().UTC().Format(time.RFC3339Nano),
	})
	item.UpdatedAt = item.CreatedAt
	if err := validateCollectionRequest(item); err != nil {
		return CollectionRequest{}, err
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO collection_requests (
			workspace_id, id, collection_id, name, server_id, server_name, server_address,
			service_name, method_name, full_method, request_json, request_metadata_json, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, item.WorkspaceID, item.ID, item.CollectionID, item.Name, item.ServerID, item.ServerName, item.ServerAddress,
		item.ServiceName, item.MethodName, item.FullMethod, item.RequestJSON, item.RequestMetadataJSON, item.CreatedAt, item.UpdatedAt)
	if err != nil {
		return CollectionRequest{}, fmt.Errorf("create collection request: %w", err)
	}
	_, _ = s.db.ExecContext(ctx, `UPDATE collections SET updated_at = ? WHERE workspace_id = ? AND id = ?`, item.UpdatedAt, localWorkspaceID, item.CollectionID)
	return item, nil
}

func (s *serverProfileStore) updateCollectionRequest(ctx context.Context, id string, request SaveCollectionRequestItemRequest) (CollectionRequest, error) {
	id = strings.TrimSpace(id)
	if id == "" {
		return CollectionRequest{}, errors.New("collection request id is required")
	}
	item := normalizeCollectionRequest(CollectionRequest{
		WorkspaceID:         localWorkspaceID,
		ID:                  id,
		CollectionID:        request.CollectionID,
		Name:                request.Name,
		ServerID:            request.ServerID,
		ServerName:          request.ServerName,
		ServerAddress:       request.ServerAddress,
		ServiceName:         request.ServiceName,
		MethodName:          request.MethodName,
		FullMethod:          request.FullMethod,
		RequestJSON:         request.RequestJSON,
		RequestMetadataJSON: request.RequestMetadataJSON,
		UpdatedAt:           time.Now().UTC().Format(time.RFC3339Nano),
	})
	if err := validateCollectionRequest(item); err != nil {
		return CollectionRequest{}, err
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE collection_requests
		SET collection_id = ?, name = ?, server_id = ?, server_name = ?, server_address = ?,
			service_name = ?, method_name = ?, full_method = ?, request_json = ?, request_metadata_json = ?, updated_at = ?
		WHERE workspace_id = ? AND id = ?
	`, item.CollectionID, item.Name, item.ServerID, item.ServerName, item.ServerAddress, item.ServiceName, item.MethodName,
		item.FullMethod, item.RequestJSON, item.RequestMetadataJSON, item.UpdatedAt, localWorkspaceID, id)
	if err != nil {
		return CollectionRequest{}, fmt.Errorf("update collection request: %w", err)
	}
	rowsAffected, err := result.RowsAffected()
	if err != nil {
		return CollectionRequest{}, fmt.Errorf("check updated collection request: %w", err)
	}
	if rowsAffected == 0 {
		return CollectionRequest{}, fmt.Errorf("collection request %q not found", id)
	}
	row := s.db.QueryRowContext(ctx, `
		SELECT workspace_id, id, collection_id, name, server_id, server_name, server_address,
			service_name, method_name, full_method, request_json, request_metadata_json, created_at, updated_at
		FROM collection_requests WHERE workspace_id = ? AND id = ?
	`, localWorkspaceID, id)
	return scanCollectionRequest(row)
}

func (s *serverProfileStore) deleteCollectionRequest(ctx context.Context, id string) error {
	id = strings.TrimSpace(id)
	if id == "" {
		return errors.New("collection request id is required")
	}
	_, err := s.db.ExecContext(ctx, `DELETE FROM collection_requests WHERE workspace_id = ? AND id = ?`, localWorkspaceID, id)
	if err != nil {
		return fmt.Errorf("delete collection request: %w", err)
	}
	return nil
}

func (s *serverProfileStore) list(ctx context.Context) ([]ServerProfile, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT workspace_id, id, name, address, tls_enabled, reflection_enabled,
			proto_files_json, proto_folders_json, metadata_json
		FROM servers
		WHERE workspace_id = ?
		ORDER BY created_at ASC, name ASC
	`, localWorkspaceID)
	if err != nil {
		return nil, fmt.Errorf("list server profiles: %w", err)
	}
	defer rows.Close()

	var profiles []ServerProfile
	for rows.Next() {
		profile, err := scanServerProfile(rows)
		if err != nil {
			return nil, err
		}
		profiles = append(profiles, profile)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read server profiles: %w", err)
	}
	return profiles, nil
}

func (s *serverProfileStore) create(ctx context.Context, request SaveServerProfileRequest) (ServerProfile, error) {
	profile := normalizeServerProfile(ServerProfile{
		WorkspaceID:       localWorkspaceID,
		ID:                uuid.NewString(),
		Name:              request.Name,
		Address:           request.Address,
		TLSEnabled:        request.TLSEnabled,
		ReflectionEnabled: request.ReflectionEnabled,
		ProtoFiles:        request.ProtoFiles,
		ProtoFolders:      request.ProtoFolders,
		MetadataJSON:      request.MetadataJSON,
	})
	if err := validateServerProfile(profile); err != nil {
		return ServerProfile{}, err
	}

	protoFilesJSON, protoFoldersJSON, err := marshalProtoLists(profile)
	if err != nil {
		return ServerProfile{}, err
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)

	_, err = s.db.ExecContext(ctx, `
		INSERT INTO servers (
			workspace_id, id, name, address, tls_enabled, reflection_enabled,
			proto_files_json, proto_folders_json, metadata_json, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, profile.WorkspaceID, profile.ID, profile.Name, profile.Address, boolToInt(profile.TLSEnabled),
		boolToInt(profile.ReflectionEnabled), protoFilesJSON, protoFoldersJSON, profile.MetadataJSON, now, now)
	if err != nil {
		return ServerProfile{}, fmt.Errorf("create server profile: %w", err)
	}
	return profile, nil
}

func (s *serverProfileStore) update(ctx context.Context, id string, request SaveServerProfileRequest) (ServerProfile, error) {
	id = strings.TrimSpace(id)
	if id == "" {
		return ServerProfile{}, errors.New("server profile id is required")
	}

	profile := normalizeServerProfile(ServerProfile{
		WorkspaceID:       localWorkspaceID,
		ID:                id,
		Name:              request.Name,
		Address:           request.Address,
		TLSEnabled:        request.TLSEnabled,
		ReflectionEnabled: request.ReflectionEnabled,
		ProtoFiles:        request.ProtoFiles,
		ProtoFolders:      request.ProtoFolders,
		MetadataJSON:      request.MetadataJSON,
	})
	if err := validateServerProfile(profile); err != nil {
		return ServerProfile{}, err
	}

	protoFilesJSON, protoFoldersJSON, err := marshalProtoLists(profile)
	if err != nil {
		return ServerProfile{}, err
	}

	result, err := s.db.ExecContext(ctx, `
		UPDATE servers
		SET name = ?, address = ?, tls_enabled = ?, reflection_enabled = ?,
			proto_files_json = ?, proto_folders_json = ?, metadata_json = ?, updated_at = ?
		WHERE workspace_id = ? AND id = ?
	`, profile.Name, profile.Address, boolToInt(profile.TLSEnabled), boolToInt(profile.ReflectionEnabled),
		protoFilesJSON, protoFoldersJSON, profile.MetadataJSON, time.Now().UTC().Format(time.RFC3339Nano),
		localWorkspaceID, id)
	if err != nil {
		return ServerProfile{}, fmt.Errorf("update server profile: %w", err)
	}
	rowsAffected, err := result.RowsAffected()
	if err != nil {
		return ServerProfile{}, fmt.Errorf("check updated server profile: %w", err)
	}
	if rowsAffected == 0 {
		return ServerProfile{}, fmt.Errorf("server profile %q not found", id)
	}
	return profile, nil
}

func (s *serverProfileStore) delete(ctx context.Context, id string) error {
	id = strings.TrimSpace(id)
	if id == "" {
		return errors.New("server profile id is required")
	}

	_, err := s.db.ExecContext(ctx, `
		DELETE FROM servers
		WHERE workspace_id = ? AND id = ?
	`, localWorkspaceID, id)
	if err != nil {
		return fmt.Errorf("delete server profile: %w", err)
	}
	return nil
}

func (s *serverProfileStore) listHistory(ctx context.Context, limit int) ([]HistoryItem, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT workspace_id, id, server_id, server_name, server_address,
			service_name, method_name, full_method, request_json, request_metadata_json,
			response_json, status_code, status_message, duration_ms, error, created_at
		FROM history_items
		WHERE workspace_id = ?
		ORDER BY created_at DESC
		LIMIT ?
	`, localWorkspaceID, limit)
	if err != nil {
		return nil, fmt.Errorf("list history items: %w", err)
	}
	defer rows.Close()

	var items []HistoryItem
	for rows.Next() {
		item, err := scanHistoryItem(rows)
		if err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read history items: %w", err)
	}
	return items, nil
}

func (s *serverProfileStore) createHistory(ctx context.Context, request SaveHistoryItemRequest) (HistoryItem, error) {
	item := normalizeHistoryItem(HistoryItem{
		WorkspaceID:         localWorkspaceID,
		ID:                  uuid.NewString(),
		ServerID:            request.ServerID,
		ServerName:          request.ServerName,
		ServerAddress:       request.ServerAddress,
		ServiceName:         request.ServiceName,
		MethodName:          request.MethodName,
		FullMethod:          request.FullMethod,
		RequestJSON:         request.RequestJSON,
		RequestMetadataJSON: request.RequestMetadataJSON,
		ResponseJSON:        request.ResponseJSON,
		StatusCode:          request.StatusCode,
		StatusMessage:       request.StatusMessage,
		DurationMs:          request.DurationMs,
		Error:               request.Error,
		CreatedAt:           time.Now().UTC().Format(time.RFC3339Nano),
	})
	if err := validateHistoryItem(item); err != nil {
		return HistoryItem{}, err
	}

	_, err := s.db.ExecContext(ctx, `
		INSERT INTO history_items (
			workspace_id, id, server_id, server_name, server_address,
			service_name, method_name, full_method, request_json, request_metadata_json,
			response_json, status_code, status_message, duration_ms, error, created_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, item.WorkspaceID, item.ID, item.ServerID, item.ServerName, item.ServerAddress,
		item.ServiceName, item.MethodName, item.FullMethod, item.RequestJSON, item.RequestMetadataJSON,
		item.ResponseJSON, item.StatusCode, item.StatusMessage, item.DurationMs, item.Error, item.CreatedAt)
	if err != nil {
		return HistoryItem{}, fmt.Errorf("create history item: %w", err)
	}
	return item, nil
}

func (s *serverProfileStore) deleteHistory(ctx context.Context, id string) error {
	id = strings.TrimSpace(id)
	if id == "" {
		return errors.New("history item id is required")
	}
	_, err := s.db.ExecContext(ctx, `
		DELETE FROM history_items
		WHERE workspace_id = ? AND id = ?
	`, localWorkspaceID, id)
	if err != nil {
		return fmt.Errorf("delete history item: %w", err)
	}
	return nil
}

func (s *serverProfileStore) clearHistory(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
		DELETE FROM history_items
		WHERE workspace_id = ?
	`, localWorkspaceID)
	if err != nil {
		return fmt.Errorf("clear history: %w", err)
	}
	return nil
}

type profileScanner interface {
	Scan(dest ...any) error
}

func scanServerProfile(scanner profileScanner) (ServerProfile, error) {
	var profile ServerProfile
	var tlsEnabled int
	var reflectionEnabled int
	var protoFilesJSON string
	var protoFoldersJSON string

	err := scanner.Scan(
		&profile.WorkspaceID,
		&profile.ID,
		&profile.Name,
		&profile.Address,
		&tlsEnabled,
		&reflectionEnabled,
		&protoFilesJSON,
		&protoFoldersJSON,
		&profile.MetadataJSON,
	)
	if err != nil {
		return ServerProfile{}, fmt.Errorf("scan server profile: %w", err)
	}

	profile.TLSEnabled = tlsEnabled != 0
	profile.ReflectionEnabled = reflectionEnabled != 0
	if err := json.Unmarshal([]byte(protoFilesJSON), &profile.ProtoFiles); err != nil {
		return ServerProfile{}, fmt.Errorf("server profile %q has invalid proto files JSON: %w", profile.ID, err)
	}
	if err := json.Unmarshal([]byte(protoFoldersJSON), &profile.ProtoFolders); err != nil {
		return ServerProfile{}, fmt.Errorf("server profile %q has invalid proto folders JSON: %w", profile.ID, err)
	}
	return normalizeServerProfile(profile), nil
}

func scanHistoryItem(scanner profileScanner) (HistoryItem, error) {
	var item HistoryItem
	err := scanner.Scan(
		&item.WorkspaceID,
		&item.ID,
		&item.ServerID,
		&item.ServerName,
		&item.ServerAddress,
		&item.ServiceName,
		&item.MethodName,
		&item.FullMethod,
		&item.RequestJSON,
		&item.RequestMetadataJSON,
		&item.ResponseJSON,
		&item.StatusCode,
		&item.StatusMessage,
		&item.DurationMs,
		&item.Error,
		&item.CreatedAt,
	)
	if err != nil {
		return HistoryItem{}, fmt.Errorf("scan history item: %w", err)
	}
	return normalizeHistoryItem(item), nil
}

func scanCollection(scanner profileScanner) (Collection, error) {
	var collection Collection
	err := scanner.Scan(
		&collection.WorkspaceID,
		&collection.ID,
		&collection.Name,
		&collection.Description,
		&collection.CreatedAt,
		&collection.UpdatedAt,
	)
	if err != nil {
		return Collection{}, fmt.Errorf("scan collection: %w", err)
	}
	return normalizeCollection(collection), nil
}

func scanCollectionRequest(scanner profileScanner) (CollectionRequest, error) {
	var item CollectionRequest
	err := scanner.Scan(
		&item.WorkspaceID,
		&item.ID,
		&item.CollectionID,
		&item.Name,
		&item.ServerID,
		&item.ServerName,
		&item.ServerAddress,
		&item.ServiceName,
		&item.MethodName,
		&item.FullMethod,
		&item.RequestJSON,
		&item.RequestMetadataJSON,
		&item.CreatedAt,
		&item.UpdatedAt,
	)
	if err != nil {
		return CollectionRequest{}, fmt.Errorf("scan collection request: %w", err)
	}
	return normalizeCollectionRequest(item), nil
}

func (s *serverProfileStore) listAllCollectionRequests(ctx context.Context) (map[string][]CollectionRequest, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT workspace_id, id, collection_id, name, server_id, server_name, server_address,
			service_name, method_name, full_method, request_json, request_metadata_json, created_at, updated_at
		FROM collection_requests
		WHERE workspace_id = ?
		ORDER BY updated_at DESC, name ASC
	`, localWorkspaceID)
	if err != nil {
		return nil, fmt.Errorf("list collection requests: %w", err)
	}
	defer rows.Close()

	requests := map[string][]CollectionRequest{}
	for rows.Next() {
		item, err := scanCollectionRequest(rows)
		if err != nil {
			return nil, err
		}
		requests[item.CollectionID] = append(requests[item.CollectionID], item)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read collection requests: %w", err)
	}
	return requests, nil
}

func normalizeServerProfile(profile ServerProfile) ServerProfile {
	profile.WorkspaceID = strings.TrimSpace(profile.WorkspaceID)
	if profile.WorkspaceID == "" {
		profile.WorkspaceID = localWorkspaceID
	}
	profile.ID = strings.TrimSpace(profile.ID)
	profile.Name = strings.TrimSpace(profile.Name)
	profile.Address = strings.TrimSpace(profile.Address)
	profile.ProtoFiles = normalizePathList(profile.ProtoFiles)
	profile.ProtoFolders = normalizePathList(profile.ProtoFolders)
	profile.MetadataJSON = strings.TrimSpace(profile.MetadataJSON)
	if profile.MetadataJSON == "" {
		profile.MetadataJSON = "{}"
	}
	return profile
}

func validateServerProfile(profile ServerProfile) error {
	if profile.Name == "" {
		return errors.New("server profile name is required")
	}
	if err := validateServerAddress(profile.Address); err != nil {
		return err
	}
	var metadata map[string]string
	if err := json.Unmarshal([]byte(profile.MetadataJSON), &metadata); err != nil {
		return fmt.Errorf("server metadata must be valid JSON: %w", err)
	}
	return nil
}

func normalizeHistoryItem(item HistoryItem) HistoryItem {
	item.WorkspaceID = strings.TrimSpace(item.WorkspaceID)
	if item.WorkspaceID == "" {
		item.WorkspaceID = localWorkspaceID
	}
	item.ID = strings.TrimSpace(item.ID)
	item.ServerID = strings.TrimSpace(item.ServerID)
	item.ServerName = strings.TrimSpace(item.ServerName)
	item.ServerAddress = strings.TrimSpace(item.ServerAddress)
	item.ServiceName = strings.TrimSpace(item.ServiceName)
	item.MethodName = strings.TrimSpace(item.MethodName)
	item.FullMethod = strings.TrimSpace(item.FullMethod)
	item.RequestJSON = strings.TrimSpace(item.RequestJSON)
	if item.RequestJSON == "" {
		item.RequestJSON = "{}"
	}
	item.RequestMetadataJSON = strings.TrimSpace(item.RequestMetadataJSON)
	if item.RequestMetadataJSON == "" {
		item.RequestMetadataJSON = "{}"
	}
	item.ResponseJSON = strings.TrimSpace(item.ResponseJSON)
	if item.ResponseJSON == "" {
		item.ResponseJSON = "{}"
	}
	item.StatusCode = strings.TrimSpace(item.StatusCode)
	item.StatusMessage = strings.TrimSpace(item.StatusMessage)
	item.Error = strings.TrimSpace(item.Error)
	item.CreatedAt = strings.TrimSpace(item.CreatedAt)
	return item
}

func validateHistoryItem(item HistoryItem) error {
	if item.ServerAddress == "" {
		return errors.New("history server address is required")
	}
	if item.FullMethod == "" {
		return errors.New("history full method is required")
	}
	if item.StatusCode == "" {
		return errors.New("history status code is required")
	}
	if !json.Valid([]byte(item.RequestJSON)) {
		return errors.New("history request JSON must be valid")
	}
	if !json.Valid([]byte(item.RequestMetadataJSON)) {
		return errors.New("history request metadata JSON must be valid")
	}
	if !json.Valid([]byte(item.ResponseJSON)) {
		return errors.New("history response JSON must be valid")
	}
	return nil
}

func normalizeCollection(collection Collection) Collection {
	collection.WorkspaceID = strings.TrimSpace(collection.WorkspaceID)
	if collection.WorkspaceID == "" {
		collection.WorkspaceID = localWorkspaceID
	}
	collection.ID = strings.TrimSpace(collection.ID)
	collection.Name = strings.TrimSpace(collection.Name)
	collection.Description = strings.TrimSpace(collection.Description)
	collection.CreatedAt = strings.TrimSpace(collection.CreatedAt)
	collection.UpdatedAt = strings.TrimSpace(collection.UpdatedAt)
	if collection.Requests == nil {
		collection.Requests = []CollectionRequest{}
	}
	return collection
}

func validateCollection(collection Collection) error {
	if collection.Name == "" {
		return errors.New("collection name is required")
	}
	return nil
}

func normalizeCollectionRequest(item CollectionRequest) CollectionRequest {
	item.WorkspaceID = strings.TrimSpace(item.WorkspaceID)
	if item.WorkspaceID == "" {
		item.WorkspaceID = localWorkspaceID
	}
	item.ID = strings.TrimSpace(item.ID)
	item.CollectionID = strings.TrimSpace(item.CollectionID)
	item.Name = strings.TrimSpace(item.Name)
	item.ServerID = strings.TrimSpace(item.ServerID)
	item.ServerName = strings.TrimSpace(item.ServerName)
	item.ServerAddress = strings.TrimSpace(item.ServerAddress)
	item.ServiceName = strings.TrimSpace(item.ServiceName)
	item.MethodName = strings.TrimSpace(item.MethodName)
	item.FullMethod = strings.TrimSpace(item.FullMethod)
	item.RequestJSON = strings.TrimSpace(item.RequestJSON)
	if item.RequestJSON == "" {
		item.RequestJSON = "{}"
	}
	item.RequestMetadataJSON = strings.TrimSpace(item.RequestMetadataJSON)
	if item.RequestMetadataJSON == "" {
		item.RequestMetadataJSON = "{}"
	}
	item.CreatedAt = strings.TrimSpace(item.CreatedAt)
	item.UpdatedAt = strings.TrimSpace(item.UpdatedAt)
	return item
}

func validateCollectionRequest(item CollectionRequest) error {
	if item.CollectionID == "" {
		return errors.New("collection id is required")
	}
	if item.Name == "" {
		return errors.New("collection request name is required")
	}
	if item.FullMethod == "" {
		return errors.New("collection request full method is required")
	}
	if !json.Valid([]byte(item.RequestJSON)) {
		return errors.New("collection request JSON must be valid")
	}
	if !json.Valid([]byte(item.RequestMetadataJSON)) {
		return errors.New("collection request metadata JSON must be valid")
	}
	return nil
}

func marshalProtoLists(profile ServerProfile) (string, string, error) {
	protoFiles, err := json.Marshal(profile.ProtoFiles)
	if err != nil {
		return "", "", fmt.Errorf("encode proto files: %w", err)
	}
	protoFolders, err := json.Marshal(profile.ProtoFolders)
	if err != nil {
		return "", "", fmt.Errorf("encode proto folders: %w", err)
	}
	return string(protoFiles), string(protoFolders), nil
}

func boolToInt(value bool) int {
	if value {
		return 1
	}
	return 0
}

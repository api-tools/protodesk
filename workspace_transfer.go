package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"
)

const workspaceExportKind = "protodesk.workspace"
const workspaceExportVersion = 1

func (s *serverProfileStore) exportWorkspace(ctx context.Context) (WorkspaceExportFile, error) {
	servers, err := s.list(ctx)
	if err != nil {
		return WorkspaceExportFile{}, err
	}
	collections, err := s.listCollections(ctx)
	if err != nil {
		return WorkspaceExportFile{}, err
	}
	return WorkspaceExportFile{
		Version:     workspaceExportVersion,
		Kind:        workspaceExportKind,
		ExportedAt:  time.Now().UTC().Format(time.RFC3339Nano),
		WorkspaceID: localWorkspaceID,
		Servers:     servers,
		Collections: collections,
	}, nil
}

func (s *serverProfileStore) importWorkspace(ctx context.Context, file WorkspaceExportFile) (WorkspaceTransferResult, error) {
	if err := validateWorkspaceExportFile(file); err != nil {
		return WorkspaceTransferResult{}, err
	}

	serverIDMap := map[string]string{}
	result := WorkspaceTransferResult{
		ServerCount:       len(file.Servers),
		CollectionCount:   len(file.Collections),
		SavedRequestCount: countWorkspaceSavedRequests(file.Collections),
	}

	for _, server := range file.Servers {
		created, err := s.create(ctx, SaveServerProfileRequest{
			Name:              importName(server.Name),
			Address:           server.Address,
			TLSEnabled:        server.TLSEnabled,
			ReflectionEnabled: server.ReflectionEnabled,
			ProtoFiles:        server.ProtoFiles,
			ProtoFolders:      server.ProtoFolders,
			MetadataJSON:      server.MetadataJSON,
		})
		if err != nil {
			return WorkspaceTransferResult{}, fmt.Errorf("import server %q: %w", server.Name, err)
		}
		serverIDMap[server.ID] = created.ID
	}

	for _, collection := range file.Collections {
		createdCollection, err := s.createCollection(ctx, SaveCollectionRequest{
			Name:        importName(collection.Name),
			Description: collection.Description,
		})
		if err != nil {
			return WorkspaceTransferResult{}, fmt.Errorf("import collection %q: %w", collection.Name, err)
		}
		for _, request := range collection.Requests {
			serverID := serverIDMap[request.ServerID]
			if serverID == "" && request.ServerID != "" {
				serverID = request.ServerID
			}
			if _, err := s.createCollectionRequest(ctx, SaveCollectionRequestItemRequest{
				CollectionID:        createdCollection.ID,
				Name:                request.Name,
				ServerID:            serverID,
				ServerName:          request.ServerName,
				ServerAddress:       request.ServerAddress,
				ServiceName:         request.ServiceName,
				MethodName:          request.MethodName,
				FullMethod:          request.FullMethod,
				RequestJSON:         request.RequestJSON,
				RequestMetadataJSON: request.RequestMetadataJSON,
			}); err != nil {
				return WorkspaceTransferResult{}, fmt.Errorf("import request %q: %w", request.Name, err)
			}
		}
	}

	return result, nil
}

func writeWorkspaceExport(path string, file WorkspaceExportFile) error {
	payload, err := json.MarshalIndent(file, "", "  ")
	if err != nil {
		return fmt.Errorf("encode workspace export: %w", err)
	}
	if err := os.WriteFile(path, append(payload, '\n'), 0o600); err != nil {
		return fmt.Errorf("write workspace export: %w", err)
	}
	return nil
}

func readWorkspaceExport(path string) (WorkspaceExportFile, error) {
	payload, err := os.ReadFile(path)
	if err != nil {
		return WorkspaceExportFile{}, fmt.Errorf("read workspace export: %w", err)
	}
	var file WorkspaceExportFile
	if err := json.Unmarshal(payload, &file); err != nil {
		return WorkspaceExportFile{}, fmt.Errorf("parse workspace export: %w", err)
	}
	if err := validateWorkspaceExportFile(file); err != nil {
		return WorkspaceExportFile{}, err
	}
	return file, nil
}

func validateWorkspaceExportFile(file WorkspaceExportFile) error {
	if file.Kind != workspaceExportKind {
		return errors.New("file is not a ProtoDesk workspace export")
	}
	if file.Version != workspaceExportVersion {
		return fmt.Errorf("unsupported workspace export version %d", file.Version)
	}
	return nil
}

func workspaceTransferResultFor(file WorkspaceExportFile) WorkspaceTransferResult {
	return WorkspaceTransferResult{
		ServerCount:       len(file.Servers),
		CollectionCount:   len(file.Collections),
		SavedRequestCount: countWorkspaceSavedRequests(file.Collections),
	}
}

func countWorkspaceSavedRequests(collections []Collection) int {
	count := 0
	for _, collection := range collections {
		count += len(collection.Requests)
	}
	return count
}

func importName(name string) string {
	trimmed := strings.TrimSpace(name)
	if trimmed == "" {
		return "Imported"
	}
	return trimmed + " (imported)"
}

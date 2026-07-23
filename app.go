package main

import (
	"context"
	"log"
	"strings"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

// App struct
type App struct {
	ctx        context.Context
	grpcClient *grpcClient
	profiles   *serverProfileStore
}

// NewApp creates a new App application struct
func NewApp() *App {
	return &App{grpcClient: newGRPCClient()}
}

// startup is called when the app starts. The context is saved
// so we can call the runtime methods
func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	databasePath, err := defaultDatabasePath()
	if err != nil {
		log.Printf("server profile storage disabled: %v", err)
		return
	}
	profiles, err := newServerProfileStore(databasePath)
	if err != nil {
		log.Printf("server profile storage disabled: %v", err)
		return
	}
	a.profiles = profiles
}

func (a *App) shutdown(ctx context.Context) {
	if err := a.profiles.close(); err != nil {
		log.Printf("close server profile storage: %v", err)
	}
}

func (a *App) ListServerProfiles() ([]ServerProfile, error) {
	store, err := a.profileStore()
	if err != nil {
		return nil, err
	}
	return store.list(a.requestContext())
}

func (a *App) CreateServerProfile(request SaveServerProfileRequest) (ServerProfile, error) {
	store, err := a.profileStore()
	if err != nil {
		return ServerProfile{}, err
	}
	return store.create(a.requestContext(), request)
}

func (a *App) UpdateServerProfile(id string, request SaveServerProfileRequest) (ServerProfile, error) {
	store, err := a.profileStore()
	if err != nil {
		return ServerProfile{}, err
	}
	return store.update(a.requestContext(), id, request)
}

func (a *App) DeleteServerProfile(id string) error {
	store, err := a.profileStore()
	if err != nil {
		return err
	}
	return store.delete(a.requestContext(), id)
}

func (a *App) ListHistoryItems(limit int) ([]HistoryItem, error) {
	store, err := a.profileStore()
	if err != nil {
		return nil, err
	}
	return store.listHistory(a.requestContext(), limit)
}

func (a *App) CreateHistoryItem(request SaveHistoryItemRequest) (HistoryItem, error) {
	store, err := a.profileStore()
	if err != nil {
		return HistoryItem{}, err
	}
	return store.createHistory(a.requestContext(), request)
}

func (a *App) DeleteHistoryItem(id string) error {
	store, err := a.profileStore()
	if err != nil {
		return err
	}
	return store.deleteHistory(a.requestContext(), id)
}

func (a *App) ClearHistory() error {
	store, err := a.profileStore()
	if err != nil {
		return err
	}
	return store.clearHistory(a.requestContext())
}

func (a *App) ListCollections() ([]Collection, error) {
	store, err := a.profileStore()
	if err != nil {
		return nil, err
	}
	return store.listCollections(a.requestContext())
}

func (a *App) CreateCollection(request SaveCollectionRequest) (Collection, error) {
	store, err := a.profileStore()
	if err != nil {
		return Collection{}, err
	}
	return store.createCollection(a.requestContext(), request)
}

func (a *App) UpdateCollection(id string, request SaveCollectionRequest) (Collection, error) {
	store, err := a.profileStore()
	if err != nil {
		return Collection{}, err
	}
	return store.updateCollection(a.requestContext(), id, request)
}

func (a *App) DeleteCollection(id string) error {
	store, err := a.profileStore()
	if err != nil {
		return err
	}
	return store.deleteCollection(a.requestContext(), id)
}

func (a *App) CreateCollectionRequest(request SaveCollectionRequestItemRequest) (CollectionRequest, error) {
	store, err := a.profileStore()
	if err != nil {
		return CollectionRequest{}, err
	}
	return store.createCollectionRequest(a.requestContext(), request)
}

func (a *App) UpdateCollectionRequest(id string, request SaveCollectionRequestItemRequest) (CollectionRequest, error) {
	store, err := a.profileStore()
	if err != nil {
		return CollectionRequest{}, err
	}
	return store.updateCollectionRequest(a.requestContext(), id, request)
}

func (a *App) DeleteCollectionRequest(id string) error {
	store, err := a.profileStore()
	if err != nil {
		return err
	}
	return store.deleteCollectionRequest(a.requestContext(), id)
}

func (a *App) ExportWorkspace() (WorkspaceTransferResult, error) {
	store, err := a.profileStore()
	if err != nil {
		return WorkspaceTransferResult{}, err
	}
	file, err := store.exportWorkspace(a.requestContext())
	if err != nil {
		return WorkspaceTransferResult{}, err
	}
	path, err := runtime.SaveFileDialog(a.requestContext(), runtime.SaveDialogOptions{
		Title:           "Export ProtoDesk workspace",
		DefaultFilename: "protodesk-workspace.json",
		Filters: []runtime.FileFilter{
			{DisplayName: "JSON files (*.json)", Pattern: "*.json"},
		},
	})
	if err != nil {
		return WorkspaceTransferResult{}, err
	}
	if path == "" {
		result := workspaceTransferResultFor(file)
		result.Skipped = true
		return result, nil
	}
	if !strings.HasSuffix(strings.ToLower(path), ".json") {
		path += ".json"
	}
	if err := writeWorkspaceExport(path, file); err != nil {
		return WorkspaceTransferResult{}, err
	}
	result := workspaceTransferResultFor(file)
	result.Path = path
	return result, nil
}

func (a *App) ImportWorkspace() (WorkspaceTransferResult, error) {
	store, err := a.profileStore()
	if err != nil {
		return WorkspaceTransferResult{}, err
	}
	path, err := runtime.OpenFileDialog(a.requestContext(), runtime.OpenDialogOptions{
		Title: "Import ProtoDesk workspace",
		Filters: []runtime.FileFilter{
			{DisplayName: "JSON files (*.json)", Pattern: "*.json"},
		},
	})
	if err != nil {
		return WorkspaceTransferResult{}, err
	}
	if path == "" {
		return WorkspaceTransferResult{Skipped: true}, nil
	}
	file, err := readWorkspaceExport(path)
	if err != nil {
		return WorkspaceTransferResult{}, err
	}
	result, err := store.importWorkspace(a.requestContext(), file)
	if err != nil {
		return WorkspaceTransferResult{}, err
	}
	result.Path = path
	return result, nil
}

func (a *App) Connect(request ConnectRequest) (ConnectResponse, error) {
	return a.grpcClient.Connect(a.requestContext(), request)
}

func (a *App) Disconnect() error {
	return a.grpcClient.Disconnect()
}

func (a *App) ListServices() (ListServicesResponse, error) {
	return a.grpcClient.ListServices()
}

func (a *App) PickProtoFiles() (PickProtoFilesResponse, error) {
	paths, err := runtime.OpenMultipleFilesDialog(a.requestContext(), runtime.OpenDialogOptions{
		Title: "Select proto files",
		Filters: []runtime.FileFilter{
			{DisplayName: "Protocol Buffer files (*.proto)", Pattern: "*.proto"},
		},
	})
	if err != nil {
		return PickProtoFilesResponse{}, err
	}
	return PickProtoFilesResponse{Paths: normalizePathList(paths)}, nil
}

func (a *App) PickProtoFolder() (PickProtoFolderResponse, error) {
	folder, err := runtime.OpenDirectoryDialog(a.requestContext(), runtime.OpenDialogOptions{
		Title:                "Select proto folder",
		CanCreateDirectories: false,
	})
	if err != nil {
		return PickProtoFolderResponse{}, err
	}
	if folder == "" {
		return PickProtoFolderResponse{}, nil
	}
	files, err := findProtoFilesInFolder(folder)
	if err != nil {
		return PickProtoFolderResponse{}, err
	}
	return PickProtoFolderResponse{
		Folder:     normalizePath(folder),
		ProtoFiles: files,
	}, nil
}

func (a *App) ValidateProtoSources(request ValidateProtoSourcesRequest) (ValidateProtoSourcesResponse, error) {
	return validateProtoSources(a.requestContext(), request), nil
}

func (a *App) Invoke(request InvokeRequest) (InvokeResponse, error) {
	return a.grpcClient.Invoke(a.requestContext(), request)
}

func (a *App) requestContext() context.Context {
	if a.ctx != nil {
		return a.ctx
	}
	return context.Background()
}

func (a *App) profileStore() (*serverProfileStore, error) {
	if a.profiles != nil {
		return a.profiles, nil
	}
	databasePath, err := defaultDatabasePath()
	if err != nil {
		return nil, err
	}
	profiles, err := newServerProfileStore(databasePath)
	if err != nil {
		return nil, err
	}
	a.profiles = profiles
	return profiles, nil
}

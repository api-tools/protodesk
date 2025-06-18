package services

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"protodesk/pkg/models/proto"

	"github.com/google/uuid"
)

// WellKnownTypesManager handles detection and management of well-known types
type WellKnownTypesManager struct {
	store ServerProfileStore
}

// NewWellKnownTypesManager creates a new well-known types manager
func NewWellKnownTypesManager(store ServerProfileStore) *WellKnownTypesManager {
	return &WellKnownTypesManager{
		store: store,
	}
}

// DetectAndStoreWellKnownTypes detects well-known types and stores them in the database
func (m *WellKnownTypesManager) DetectAndStoreWellKnownTypes(ctx context.Context) error {
	fmt.Printf("[DEBUG] Detecting well-known types...\n")

	// Find protobuf include path
	includePath, err := findProtobufIncludePath()
	if err != nil {
		return fmt.Errorf("failed to find protobuf include path: %w", err)
	}

	fmt.Printf("[DEBUG] Found protobuf include path: %s\n", includePath)

	// Define well-known types to look for
	wellKnownTypes := []string{
		"timestamp",
		"empty",
		"any",
		"struct",
		"wrappers",
		"duration",
		"field_mask",
		"source_context",
		"type",
	}

	for _, typeName := range wellKnownTypes {
		filePath := fmt.Sprintf("google/protobuf/%s.proto", typeName)
		fullPath := filepath.Join(includePath, filePath)

		// Check if file exists
		if _, err := os.Stat(fullPath); err != nil {
			fmt.Printf("[DEBUG] Well-known type %s not found at %s\n", typeName, fullPath)
			continue
		}

		// Read file content
		content, err := os.ReadFile(fullPath)
		if err != nil {
			fmt.Printf("[WARN] Failed to read %s: %v\n", fullPath, err)
			continue
		}

		// Check if already exists
		existing, err := m.store.GetWellKnownType(ctx, fmt.Sprintf("google.protobuf.%s", typeName))
		if err == nil && existing != nil {
			// Update if content changed
			if existing.Content != string(content) {
				existing.Content = string(content)
				existing.UpdatedAt = time.Now()
				if err := m.store.UpdateWellKnownType(ctx, existing); err != nil {
					fmt.Printf("[WARN] Failed to update well-known type %s: %v\n", typeName, err)
				} else {
					fmt.Printf("[DEBUG] Updated well-known type: %s\n", typeName)
				}
			}
			continue
		}

		// Create new well-known type
		wkt := &proto.WellKnownType{
			ID:          uuid.New().String(),
			TypeName:    fmt.Sprintf("google.protobuf.%s", typeName),
			FilePath:    filePath,
			IncludePath: includePath,
			Content:     string(content),
			CreatedAt:   time.Now(),
			UpdatedAt:   time.Now(),
		}

		if err := m.store.CreateWellKnownType(ctx, wkt); err != nil {
			fmt.Printf("[WARN] Failed to create well-known type %s: %v\n", typeName, err)
		} else {
			fmt.Printf("[DEBUG] Stored well-known type: %s\n", typeName)
		}
	}

	return nil
}

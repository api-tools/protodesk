package proto

import "time"

// WellKnownType represents a well-known protobuf type
type WellKnownType struct {
	ID          string    `json:"id"`
	TypeName    string    `json:"typeName"`    // e.g., "google.protobuf.Timestamp"
	FilePath    string    `json:"filePath"`    // e.g., "google/protobuf/timestamp.proto"
	IncludePath string    `json:"includePath"` // e.g., "/usr/local/include"
	Content     string    `json:"content"`     // The actual proto file content
	CreatedAt   time.Time `json:"createdAt"`
	UpdatedAt   time.Time `json:"updatedAt"`
}

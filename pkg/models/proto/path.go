package proto

import "time"

// ProtoPath represents a path containing proto files for a server profile
type ProtoPath struct {
	ID              string
	ServerProfileID string
	Path            string
	Hash            string    // Hash of the proto files in this path
	LastScanned     time.Time // When this path was last scanned
}

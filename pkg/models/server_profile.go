package models

import (
	"time"

	"github.com/google/uuid"
)

// ServerProfile represents a gRPC server connection profile
type ServerProfile struct {
	ID              string    `json:"id" db:"id"`
	Name            string    `json:"name" db:"name"`
	Host            string    `json:"host" db:"host"`
	Port            int       `json:"port" db:"port"`
	TLSEnabled      bool      `json:"tlsEnabled" db:"tls_enabled"`
	CertificatePath *string   `json:"certificatePath,omitempty" db:"certificate_path"`
	UseReflection   bool      `json:"useReflection" db:"use_reflection"`
	CreatedAt       time.Time `json:"createdAt" db:"created_at"`
	UpdatedAt       time.Time `json:"updatedAt" db:"updated_at"`
}

// NewServerProfile creates a new server profile with default values
func NewServerProfile(name, host string, port int) *ServerProfile {
	now := time.Now()
	return &ServerProfile{
		ID:            uuid.New().String(),
		Name:          name,
		Host:          host,
		Port:          port,
		UseReflection: false,
		CreatedAt:     now,
		UpdatedAt:     now,
	}
}

// Validate checks if the server profile has valid values
func (s *ServerProfile) Validate() error {
	if s.Name == "" {
		return ErrEmptyName
	}
	if s.Host == "" {
		return ErrEmptyHost
	}
	if s.Port < 1 || s.Port > 65535 {
		return ErrInvalidPort
	}
	return nil
}

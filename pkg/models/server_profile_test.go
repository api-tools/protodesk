package models

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestNewServerProfile(t *testing.T) {
	name := "test-server"
	host := "localhost"
	port := 50051

	profile := NewServerProfile(name, host, port)

	assert.NotEmpty(t, profile.ID)
	assert.Equal(t, name, profile.Name)
	assert.Equal(t, host, profile.Host)
	assert.Equal(t, port, profile.Port)
	assert.False(t, profile.TLSEnabled)
	assert.Nil(t, profile.CertificatePath)
	assert.NotZero(t, profile.CreatedAt)
	assert.NotZero(t, profile.UpdatedAt)
	assert.Equal(t, profile.CreatedAt, profile.UpdatedAt)
}

func TestServerProfile_Validate(t *testing.T) {
	tests := []struct {
		name    string
		profile *ServerProfile
		wantErr error
	}{
		{
			name: "valid profile",
			profile: &ServerProfile{
				ID:   "test-id",
				Name: "test-server",
				Host: "localhost",
				Port: 50051,
			},
			wantErr: nil,
		},
		{
			name: "empty name",
			profile: &ServerProfile{
				ID:   "test-id",
				Name: "",
				Host: "localhost",
				Port: 50051,
			},
			wantErr: ErrEmptyName,
		},
		{
			name: "empty host",
			profile: &ServerProfile{
				ID:   "test-id",
				Name: "test-server",
				Host: "",
				Port: 50051,
			},
			wantErr: ErrEmptyHost,
		},
		{
			name: "port too low",
			profile: &ServerProfile{
				ID:   "test-id",
				Name: "test-server",
				Host: "localhost",
				Port: 0,
			},
			wantErr: ErrInvalidPort,
		},
		{
			name: "port too high",
			profile: &ServerProfile{
				ID:   "test-id",
				Name: "test-server",
				Host: "localhost",
				Port: 65536,
			},
			wantErr: ErrInvalidPort,
		},
		{
			name: "valid with TLS",
			profile: &ServerProfile{
				ID:              "test-id",
				Name:            "test-server",
				Host:            "localhost",
				Port:            50051,
				TLSEnabled:      true,
				CertificatePath: strPtr("/path/to/cert"),
			},
			wantErr: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.profile.Validate()
			if tt.wantErr != nil {
				assert.Equal(t, tt.wantErr, err)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

// Helper function to get string pointer
func strPtr(s string) *string {
	return &s
}

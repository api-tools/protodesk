package models

import "time"

type PerRequestHeaders struct {
	ID              int       `db:"id"`
	ServerProfileID string    `db:"server_profile_id"`
	ServiceName     string    `db:"service_name"`
	MethodName      string    `db:"method_name"`
	HeadersJSON     string    `db:"headers_json"`
	UpdatedAt       time.Time `db:"updated_at"`
}

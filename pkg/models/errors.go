package models

import "errors"

var (
	// ErrEmptyName is returned when the server profile name is empty
	ErrEmptyName = errors.New("server profile name cannot be empty")

	// ErrEmptyHost is returned when the server host is empty
	ErrEmptyHost = errors.New("server host cannot be empty")

	// ErrInvalidPort is returned when the server port is invalid
	ErrInvalidPort = errors.New("server port must be between 1 and 65535")

	// ErrProfileNotFound is returned when a profile cannot be found
	ErrProfileNotFound = errors.New("server profile not found")
)

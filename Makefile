.PHONY: dev build clean test lint

# Development
dev:
	wails dev

# Build for current platform
build:
	wails build

# Build for all platforms
build-all:
	wails build -platform darwin/universal,windows/amd64,linux/amd64

# Clean build artifacts
clean:
	rm -rf build/bin
	cd frontend && rm -rf dist node_modules

# Run tests
test:
	go test ./...
	cd frontend && npm run test

# Install dependencies
deps:
	go mod tidy
	cd frontend && npm install

# Lint code
lint:
	cd frontend && npm run lint

# Generate Wails bindings
generate:
	wails generate module

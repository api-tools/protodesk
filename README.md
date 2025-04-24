# ProtoDesk

A modern gRPC client desktop application built with Wails, Go, and Vue.js.

## Features (Planned)

- Server profile management for gRPC connections
- Protocol Buffer file parsing and management
- Service discovery through gRPC reflection
- Interactive request builder
- Response visualization
- Multi-tab support for concurrent sessions
- Dark/light theme support

## Development

### Prerequisites

- Go 1.21+
- Node.js and npm
- Wails CLI

### Setup

1. Install dependencies:
```bash
# Install Go dependencies
go mod tidy

# Install frontend dependencies
cd frontend && npm install
```

2. Run in development mode:
```bash
wails dev
```

3. Build for production:
```bash
wails build
```

## Project Structure

- `/internal/app`: Core application logic
- `/pkg/services`: gRPC client and service implementations
- `/pkg/models`: Data models and types
- `/frontend/src`:
  - `/components`: Vue components
  - `/views`: Vue views/pages
  - `/stores`: Pinia state management
  - `/types`: TypeScript type definitions
  - `/utils`: Utility functions

## License

[MIT License](LICENSE)

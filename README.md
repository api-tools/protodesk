# ProtoDesk

ProtoDesk is a local-first desktop gRPC client built with Wails, Vue 3, TypeScript, Pinia, and Go.

> [!NOTE]
> ProtoDesk is under active development. The current release is an MVP intended
> for local development and evaluation, not a production-ready security tool.

The MVP is focused on a desktop-native gRPC workflow:

```text
Connect -> Select Method -> Edit Request -> Invoke -> Inspect Response
```

## Current Features

- Resizable three-column desktop shell with top connection panel and bottom status panel.
- Pinia-backed app state for connection, services, selected method, request draft, response, and status.
- Insecure and TLS gRPC connection support.
- Server reflection discovery for services and methods.
- SQLite-backed saved server profiles with local workspace IDs.
- Saved collections and reusable request templates.
- Local workspace import/export for servers, proto references, collections, and saved requests.
- Manual proto file and folder selection, validation, service discovery, and unary invocation.
- Local invocation history with request and response snapshots.
- Unary dynamic invocation from JSON request bodies.
- Type-aware repeated-field editors with per-item controls and Form/JSON modes for message values.
- Metadata headers, timeout, and optional authority override.
- Reflection-first discovery with automatic proto fallback when reflection is disabled or unavailable.
- Clear reflection-unavailable, proto-source, invalid JSON, gRPC error, and streaming-not-implemented states.

## Requirements

- Go 1.25 toolchain support.
- Node.js 22 or newer.
- Wails 2.10 or newer.

## Development

Install frontend dependencies:

```sh
cd frontend
npm install
```

Run the desktop app:

```sh
wails dev
```

Run only the frontend in a browser:

```sh
cd frontend
npm run dev
```

## Verification

Run all checks before considering a change complete:

```sh
cd frontend
npm audit
npm run test
npm run build
```

```sh
go test ./...
```

Security rule: dependency vulnerabilities should be fixed immediately. Do not leave a known vulnerable package in the tree unless a documented, explicit exception is made.

For vulnerability reporting, see [SECURITY.md](SECURITY.md).

## Build

Create a production desktop build:

```sh
wails build
```

## MVP Limits

- Unary calls are supported.
- Streaming methods are discovered but return a clear MVP error when invoked.
- Environments and streaming UIs are later roadmap items.
- Satoshi is bundled locally as the primary UI font. See `docs/third-party-notices.md`.

## License

No open-source license has been selected yet. Unless otherwise stated, all rights are reserved.

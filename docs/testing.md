# Testing

## Frontend

Run:

```sh
cd frontend
npm audit
npm run test
npm run build
```

Frontend tests use Vitest, jsdom, Vue Test Utils, and mocked Wails bindings.

Covered behavior:

- Initial disconnected state.
- Connection setting updates.
- Reflection unavailable warning state.
- Method selection.
- Invalid JSON blocking.
- Enabled metadata filtering.
- Server profile load/create/update/delete behavior.
- Empty persistence fallback to the local default server.
- Invocation history capture, modal preview, load request, copy, delete, and clear behavior.
- Collection modal, save current request, save from history, load request, and delete behavior.
- Workspace import/export store actions and modal summary behavior.
- Type-aware repeated scalar, enum, boolean, wrapper, and message editing.
- Structured message Form/JSON switching, invalid item JSON protection, and recursive-schema fallback.
- Top toolbar action visibility and event wiring.
- Disconnect state clearing.

## Backend

Run:

```sh
go test ./...
```

Backend tests start an in-process gRPC server using generated gRPC interop descriptors.

Covered behavior:

- Server address validation.
- Reflection discovery.
- Nested message schema discovery, enum preservation, and recursive descriptor termination.
- Reflection-unavailable non-fatal connect.
- Proto-only service discovery and unary invocation.
- Reflection-unavailable fallback to local proto descriptors.
- Proto compilation failures preserve the established connection as a warning state.
- Proto imports cannot escape configured roots through parent paths or symlinks.
- Unary success.
- Unary gRPC error mapping.
- Streaming MVP error.
- Server profile schema initialization and CRUD.
- Invocation history schema initialization and CRUD.
- Collection and saved request schema initialization and CRUD.
- Workspace export/import round trip, file read/write, version validation, and saved request server ID remapping.
- Corrupt persisted proto list handling.

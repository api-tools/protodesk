# Architecture

ProtoDesk uses Wails as the desktop bridge between a Vue frontend and a Go gRPC backend.

## Frontend

- Vue renders the desktop workspace.
- Pinia owns connection, service, request, response, and status state.
- Components are controlled by the store and emit intent events rather than owning app workflow.
- Request and response JSON use monospace presentation; UI text uses bundled Satoshi with system fallbacks.
- Reflected methods include a cycle-safe message-type registry. The request editor resolves message references through that registry to render nested forms, while retaining JSON mode for dynamic objects, recursive references, and advanced editing.
- Repeated fields are stored as normal protobuf JSON arrays; their per-item controls only change presentation and do not change invocation or persistence formats.

## Backend

- The Wails `App` exposes gRPC connection/invocation methods, proto source picker/validation methods, local persistence methods, and workspace import/export methods.
- `grpcClient` owns the active connection, reflected service descriptors, and method descriptor lookup.
- Descriptor discovery collects request fields and all reachable message schemas by fully qualified name without recursively embedding descriptor trees.
- `serverProfileStore` owns the local SQLite database and persists server profiles, invocation history, collections, and saved requests under `workspaceId = "local"`.
- Workspace export serializes server profiles, proto source references, collections, and saved requests into a versioned JSON file. Import validates the file and duplicates records locally instead of overwriting existing data.
- Reflection is optional. If reflection fails after a successful dial, the connection remains active and the frontend receives a non-fatal warning state.
- Descriptor precedence is reflection first when enabled, then configured local proto sources as fallback. With reflection disabled, configured proto sources are compiled directly and populate the same service and method model.
- Proto compilation is time-bounded, rejects absolute and parent-directory imports, and only resolves dependencies inside configured import roots or the standard protobuf imports.
- Unary calls use the active reflection or proto method descriptor, dynamic request messages, request metadata, timeout, and optional authority override.

## Data Flow

```text
Vue control -> Pinia action -> Wails binding -> Go App -> grpcClient -> gRPC server
```

Responses flow back through the same path and update the right response panel plus bottom status line.

Server profile, history, collection, and workspace transfer flows follow the same frontend path but terminate in the local SQLite store or file dialog bridge.

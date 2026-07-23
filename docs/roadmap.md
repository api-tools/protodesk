# ProtoDesk Roadmap

## Product Direction

ProtoDesk is service-first, not request-first. Unlike REST tools that start from manually created collections and requests, ProtoDesk starts from the gRPC API surface:

```text
Server -> Service -> Method
```

Reflection and proto files define the available API. Users discover methods, edit generated request payloads, invoke calls, and save useful examples for reuse. Collections are not API definitions; they are sets of known working request examples attached to discovered services and methods.

The long-term product opportunity is a developer workspace centered around gRPC services: shared examples, onboarding flows, debugging scenarios, service ownership, documentation, repository links, schema changes, and standardized workflows. The desktop client is the hook; collaboration and shared service knowledge are where larger business value emerges.

## MVP

- Fixed Wails desktop shell with top connection panel, three main columns, and bottom status panel.
- gRPC server connection with insecure and TLS modes.
- Server reflection discovery for services and methods.
- Saved server profiles in local SQLite storage.
- Saved collections and reusable request templates.
- Local workspace import/export for server profiles, proto source references, collections, and saved request examples.
- Manual `.proto` file and folder loading with validation, discovery, and unary invocation.
- Local invocation history with request and response snapshots.
- Unary method invocation with JSON request bodies.
- Type-aware request fields, including individual repeated values and structured/JSON message editing.
- Metadata editor with enabled and disabled rows.
- Timeout call option.
- Response viewer with status, duration, body, and errors.
- Backend and frontend tests for connection, reflection, invocation, state, and validation.

## Next Priorities

1. Better request history.
2. Metadata presets.
3. Secret redaction and local keychain preparation.
4. Collection schema compatibility.
5. Advanced method filters.
6. Environment variables.

Import/export and proto-backed discovery are now part of the local MVP. The next work should improve daily reuse while reducing secret exposure: richer history browsing, reusable metadata presets, secret redaction, collection compatibility checks, stronger method filtering, and then environment variables once shared collections make placeholders more valuable.

## Collections

- Collections are saved request examples, not API definitions.
- Saved requests should remain linked to `serviceName`, `methodName`, and `fullMethod`.
- Saved requests should also store schema compatibility metadata over time, such as request type, response type, schema hash, and proto source information.
- Collections should remain editable even when a method is missing or a proto schema changes.
- Future collection loading should show compatibility states:
  - Compatible schema: load normally.
  - Changed schema: load with warning.
  - Missing method: mark unresolved but keep the saved example editable.

Example collection shape:

```text
SportsService.GetMatches
- Today's matches
- Live matches
- Historical matches

SportsService.GetSeasons
- Active seasons
- All seasons
```

## Import And Export

- Export produces a portable workspace JSON file.
- Export includes server profiles, proto source references, collections, and saved request examples.
- Request history is excluded by default, with optional export later.
- Import validates file kind and version before writing data.
- Import creates new local records by default rather than overwriting existing records.
- Import preserves service/method metadata so saved examples can later be checked against the currently loaded schema.
- Future import previews should warn, not fail, when local proto paths or server addresses are unavailable on the importing machine.

## Design System

- Keep Satoshi as the bundled primary UI typeface.
- Keep a system font fallback stack for platforms where bundled font loading fails.
- Use a monospace font for request and response editors.
- Continue documenting bundled third-party visual assets in `docs/third-party-notices.md`.

## Later

- Server, client, and bidirectional streaming UIs.
- Environment variables and secret handling.
- Keyboard shortcuts.
- Service catalog features such as owners, docs, repository links, and schema change notes.

## Team Workspace Planning

The app should be planned as a local-first desktop gRPC client that can later support team workspaces without requiring a rewrite. The first MVP should remain personal and offline-capable, but the internal data model should already assume that every server, request, collection, environment, and history item belongs to a `workspaceId`. In the MVP, this can simply be `workspaceId = "local"`.

A future team workspace should allow multiple developers to share common gRPC setup: server profiles, request examples, metadata presets, proto sources, example payloads, documentation notes, and collections. The app should clearly separate private local data from shared team data. Personal request history, scratch requests, bearer tokens, API keys, local variables, and temporary metadata should stay local by default. Shared team data should include reusable configuration only, such as server addresses, request examples, metadata placeholders, proto references, and documentation.

The long-term structure should be based on `Workspace -> Server -> Environment -> Collection -> Request`. A workspace can be either local or team-based. Example workspace types: `Personal Workspace`, `Backend Team`, `Payments Team`, `Sports API Team`, or `Internal Tools`. The UI can later include a workspace switcher in the top panel, for example `[ Personal Workspace v ]`, and later `[ Sports API Team v ]`.

Team roles should stay simple: `Owner`, `Admin`, `Editor`, and `Viewer`. The owner can manage billing, delete the workspace, and manage admins. Admins can invite members and manage shared servers, environments, and collections. Editors can create and edit shared requests. Viewers can use shared requests but not modify shared configuration.

Secrets must not be shared by default. Shared metadata should support placeholders such as `authorization: Bearer {{AUTH_TOKEN}}` or `x-tenant-id: {{TENANT_ID}}`, while the actual values are stored locally per user, preferably in the operating system keychain later. This allows a team to share the structure of a request without accidentally sharing real tokens or credentials.

The future team data model should roughly follow this shape: `users/{userId}`, `workspaces/{workspaceId}`, `workspaces/{workspaceId}/members/{userId}`, `workspaces/{workspaceId}/servers/{serverId}`, `workspaces/{workspaceId}/environments/{environmentId}`, `workspaces/{workspaceId}/collections/{collectionId}`, `workspaces/{workspaceId}/collections/{collectionId}/requests/{requestId}`, and `workspaces/{workspaceId}/protoSources/{protoSourceId}`. Locally, the SQLite schema should mirror this structure so that cloud sync can be added later without changing the whole app model.

The commercial model should support this progression: free personal desktop client first, then paid pro features, then team workspaces. Free can include local servers, reflection, unary calls, metadata, local history, local collections, and local import/export. Pro can include advanced history, proto file loading, mTLS profiles, metadata presets, collection compatibility checks, and richer workspace management. Team can include shared workspaces, shared servers, shared collections, shared metadata presets, members, roles, cloud sync, and audit logs.

Team features should not be part of the first MVP, but the MVP should be built in a way that does not block them later. The important immediate decision is to include `workspaceId`, `serverId`, `collectionId`, `requestId`, and `environmentId` in the local state and persistence model from the beginning.

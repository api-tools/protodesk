# ProtoDesk

A local-first Flutter desktop client for dynamic gRPC APIs on macOS, Windows, and Linux.

Choose a server → browse services and methods → edit a request → invoke → inspect the response.

## Features

- Resizable three-pane dark workspace, service/method filtering, shared Satoshi typography, compact 36 px controls, and Roboto Mono JSON/code. Service and method rows use consistent spacing.
- Searchable, collapsible JSON responses with quoted keys/values, expand/collapse all, full JSON copy, highlighted matches and ancestor context. Clearing search restores expansion; each call starts with fresh expansion state.
- gRPC status, duration, message count and live stream state in the footer. Response headers/trailers open in a compact secondary dialog with copy and empty states; request metadata stays editable.
- Plaintext or verified TLS connections, optional PEM mTLS client identity, separate reflection/RPC metadata, reflection v1/v1alpha, request headers, deadlines, and optional SNI/authority overrides. See [connection security](docs/CONNECTION_SECURITY.md).
- Reflection-first API discovery with offline local/Git schema fallback. Combine native file/folder imports and public or credential-backed private GitHub repositories by branch/tag/commit, select entry points, configure independent import roots, validate with bundled protoc, and reuse validated revisions offline. Persistent file access on macOS. See [source management](docs/PROTOBUF_SOURCES.md).
- Runtime protobuf descriptors and JSON encoding: user APIs do not need generated application classes. Supports scalar types, 64-bit string integers, bytes, enums, maps, repeated/nested/recursive messages, oneofs, presence, and well-known JSON types.
- Schema-aware Form/JSON editing, individual repeated-item controls, enum and boolean controls, timestamp date/time selection, and validation that retains invalid local drafts.
- Unary, server-streaming, client-streaming and bidirectional RPCs. Compose Form/JSON messages, queue snapshots, start a request stream, send messages and explicitly finish sending. Bidirectional replies and headers arrive while the send side remains open. Cancellation, deadlines and errors retain partial responses. Incoming data is capped at 1,000 messages / 64 MiB; the send queue at 64 messages / 32 MiB, with 1,000 messages / 64 MiB wire and JSON per request stream.
- SQLite saved servers, collections of reusable requests and streaming sequences, local invocation history, and version 2 JSON workspace export with version 1/2 import compatibility. Imports duplicate records and remap server IDs; exports omit history.

Proto2/proto3 schemas are supported; protobuf editions are currently rejected with an actionable error. Proto loading is bounded to 2,048 files, 32 MiB total, 4 MiB per file, and a 10-second compiler deadline. Absolute/parent imports and symlinks escaping configured roots are rejected. Requests/responses are bounded to 32 MiB and 64 nested message levels.

See [protected credentials](docs/CREDENTIALS.md) for OS-store references, explicit literal migration, private GitHub access and safe workspace/diagnostic exports.

Use the toolbar terminal icon for [safe grpcurl import/export](docs/GRPCURL_INTERCHANGE.md), including explicit sensitive-data choices, native file references and saved request options.

## Downloads

Download the tested [current production release](https://github.com/api-tools/protodesk/releases/latest) or browse [Releases](https://github.com/api-tools/protodesk/releases). Development releases use `dev-v*` tags and are explicitly marked as prereleases; production `v*` tags retain the separate fail-closed signing/notarization gate. End users do not need Flutter, Dart, or protoc.

- macOS: extract `ProtoDesk.app`. Production `ProtoDesk-macos-universal.zip` is universal Intel/Apple Silicon, Developer ID signed, Apple notarized and stapled. Distinct `ProtoDesk-macos-development.zip` prereleases are ad-hoc signed and **not notarized**.
- Windows x64: extract the entire ZIP and run `protodesk.exe`. The executable is **unsigned**; retain the DLLs and data directory beside it.
- Linux x64: extract the archive and run `bundle/protodesk`. GTK 3, libsecret (`libsecret-1-0`) and the usual desktop system libraries must be installed. Protected credentials additionally require a running Secret Service; public sources and literal headers do not require credential-store access.

## Local data

The database is `ProtoDesk/protodesk.sqlite` below the OS configuration directory:

- macOS: `~/Library/Application Support/ProtoDesk/`
- Windows: `%APPDATA%\ProtoDesk\`
- Linux: `$XDG_CONFIG_HOME/ProtoDesk/` or `~/.config/ProtoDesk/`

Opening an existing database creates a consistent SQLite snapshot in `backups/` before schema initialization. Existing record IDs, timestamps, collections, requests, and history are retained. Workspace exports may contain credentials in metadata; store them privately. Proto references identify local paths and do not embed source files. On macOS, reselect previously configured sources once to grant persistent sandbox access if needed.

## Development

Requires Flutter 3.47.7 / Dart 3.13.5 or compatible newer versions, and desktop build tools for the host OS. Python 3 is used only to prepare the checksum-verified compiler dependency and run release diagnostics.

```sh
python3 tool/prepare_protoc.py
flutter pub get
flutter run -d macos   # or windows / linux on the matching OS
```

```sh
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze
flutter test
python3 tool/build_desktop.py macos   # or windows / linux
python3 tool/package_macos.py development  # explicit ad-hoc development ZIP
```

Production Developer ID distribution requires Apple Accepted, stapling and extracted-package verification; see [the distribution guide](docs/MACOS_DISTRIBUTION.md). Existing signed production releases include checksum-bound notarization receipts. Development releases do not need those credentials; their ad-hoc macOS status is explicit.

Tests use a new Dart fixture service and an API schema loaded at runtime. They cover wire interoperability with protoc, reflection variants, proto-only discovery, unary errors and deadlines, TLS trust, metadata, streaming completion/failure/cancellation/limits, request editors, SQLite persistence, and transactional workspace transfer. CI builds and exercises compiled releases separately on all three operating systems.

macOS retains the app sandbox. Its compiler helper inherits the sandbox, networking is enabled for gRPC, selected files use security-scoped bookmarks, and a narrow directory permission preserves access to the ProtoDesk database.

## License

Application code: [MIT](LICENSE). Fonts, protobuf tools, Flutter, and other dependencies retain their respective licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).

Call timelines and serialized protobuf metrics are documented in [Call diagnostics](docs/CALL_DIAGNOSTICS.md).

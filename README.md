# ProtoDesk

A local-first Flutter desktop client for dynamic gRPC APIs on macOS, Windows, and Linux.

Choose a server → browse services and methods → edit a request → invoke → inspect the response.

## Features

- Resizable three-pane dark workspace, service/method filtering, shared Satoshi typography, compact 36 px controls, and Roboto Mono JSON/code. Service and method rows use consistent spacing.
- Searchable, collapsible JSON responses with quoted keys/values, expand/collapse all, full JSON copy, highlighted matches and ancestor context. Clearing search restores expansion; each call starts with fresh expansion state.
- gRPC status, duration, message count and live stream state in the footer. Response headers/trailers open in a compact secondary dialog with copy and empty states; request metadata stays editable.
- Plaintext or verified TLS connections, reflection v1/v1alpha, request headers, deadlines, and optional authority overrides.
- Reflection-first API discovery with local `.proto` fallback. Native file/folder selection, standard imports, source validation, and persistent file access on macOS.
- Runtime protobuf descriptors and JSON encoding: user APIs do not need generated application classes. Supports scalar types, 64-bit string integers, bytes, enums, maps, repeated/nested/recursive messages, oneofs, presence, and well-known JSON types.
- Schema-aware Form/JSON editing, individual repeated-item controls, enum and boolean controls, timestamp date/time selection, and validation that retains invalid local drafts.
- Unary calls and incremental server streams, with cancellation, headers/trailers, elapsed time, partial results on failure, and limits of 1,000 messages / 64 MiB of buffered wire data.
- SQLite saved servers, collections of reusable requests, local invocation history, and version 1 JSON workspace import/export. Imports duplicate records and remap server IDs; exports omit history.

Client and bidirectional streaming are explicitly unsupported. Proto2/proto3 schemas are supported; protobuf editions are currently rejected with an actionable error. Proto loading is bounded to 2,048 files, 32 MiB total, 4 MiB per file, and a 10-second compiler deadline. Absolute/parent imports and symlinks escaping configured roots are rejected. Requests/responses are bounded to 32 MiB and 64 nested message levels.

## Downloads

Download the complete desktop bundle from [Releases](https://github.com/api-tools/protodesk/releases). End users do not need Flutter, Dart, or protoc.

- macOS: extract `ProtoDesk.app`. Universal Intel/Apple Silicon app, ad-hoc signed, **not notarized**. macOS may require explicit approval to open an app downloaded outside the App Store.
- Windows x64: extract the entire ZIP and run `protodesk.exe`. The executable is **unsigned**; retain the DLLs and data directory beside it.
- Linux x64: extract the archive and run `bundle/protodesk`. GTK 3 and the usual desktop system libraries must be installed.

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
flutter build macos --release   # or windows / linux
sh tool/package_macos.sh        # macOS: verify signatures and create complete ZIP
```

Tests use a new Dart fixture service and an API schema loaded at runtime. They cover wire interoperability with protoc, reflection variants, proto-only discovery, unary errors and deadlines, TLS trust, metadata, streaming completion/failure/cancellation/limits, request editors, SQLite persistence, and transactional workspace transfer. CI builds and exercises compiled releases separately on all three operating systems.

macOS retains the app sandbox. Its compiler helper inherits the sandbox, networking is enabled for gRPC, selected files use security-scoped bookmarks, and a narrow directory permission preserves access to the ProtoDesk database.

## License

Application code: [MIT](LICENSE). Fonts, protobuf tools, Flutter, and other dependencies retain their respective licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).

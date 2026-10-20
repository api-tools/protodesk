# ProtoDesk 1.0.5 development release

Fresh installations start with zero servers, collections, saved requests and history. No endpoint is prefilled and no connection starts automatically. Empty states guide users to add their own server. Existing saved data, including earlier Localhost profiles, is preserved on upgrade.

Previously local fixes from example-server testing are reviewed and included:

- Per-profile custom TLS CA selection with bounded certificate loading, sandbox bookmarks, migration and restart/import preservation. System roots remain the default; no test certificate is bundled or trusted automatically.
- Nested Form fixes for repeated row identity, map validation, aliases/oneofs, offscreen invalid drafts and validation before send or JSON switching.
- Well-known-type fixes for plain Timestamp/Duration/FieldMask inputs, historical date/time and nanosecond preservation, explicit Value null and empty StringValue/BytesValue presence.

The separate Example Server, local user databases, profiles, logs and credentials are excluded from distributed bundles. Standard protobuf definitions remain bundled for dynamic schema compilation. Self-contained test fixtures are development dependencies and are not runtime assets or user-data seeds. Release CI audits archive contents and verifies fresh startup/restart with isolated empty storage on all three desktop platforms.

Validation: formatter/analyzer, 64 Flutter tests, 12 distribution-script tests, desktop release builds, compiled reflection/proto smoke for all four RPC modes, and fresh packaged startup. The macOS package was also inspected interactively with isolated storage.

macOS is **ad-hoc signed and not notarized**; Windows is unsigned. Signed/notarized production releases use a separate verified distribution path; this development archive does not. No Flutter, Dart or protoc installation is needed to run the bundle.

## Run the downloaded bundle

- macOS: extract `ProtoDesk-macos-development.zip` and open `ProtoDesk.app`. Universal Intel/Apple Silicon; macOS may require explicit approval for this downloaded development app. Do not disable Gatekeeper.
- Windows x64: extract the complete ZIP and run `protodesk.exe`; keep its DLLs/data beside it.
- Linux x64: extract the archive and run `bundle/protodesk`; GTK 3, libsecret (`libsecret-1-0`) and desktop system libraries are required; protected credentials additionally need a running Secret Service.

Verify downloaded files against `SHA256SUMS.txt`. Optional `PROTODESK_DATA_DIR` selects an explicit absolute directory for isolated or portable user storage; without it the existing platform storage path is unchanged. It never clears data.

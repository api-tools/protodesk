# Clean development release checks — 1.0.5

Fresh database startup and restart create zero servers, collections, saved requests and history. The controller no longer seeds Localhost; New server starts with a blank address. No automatic connection occurs. Normal storage paths and existing IDs/data remain unchanged; startup does not remove old default or user-created profiles. Regression coverage includes a compatible legacy database with a Localhost profile.

Local macOS validation passed: 64 Flutter tests, formatter/analyzer, 12 packaging/build-script tests, release build, extracted-package reflection/proto smoke for all four gRPC modes and SQLite persistence, and extracted-package fresh startup/restart with all four user table counts zero. The actual extracted app was inspected with an explicitly isolated empty storage directory: Select server, Disconnected, zero services/methods, blank New server address and empty Servers/Collections/History. Counts remained zero after closing all dialogs. Existing owner storage was not cleared or replaced.

Archive audit passed (71 ZIP entries on the local macOS build). Runtime assets comprise fonts, licenses and standard protobuf compiler/definitions. Test fixtures, example-server project, local databases/profiles/bookmarks, test certificates/private keys and logs are absent. The sibling Example Server stays outside this repository and all published bundles.

The audit initially caught native debug-symbol paths and Flutter's generated plugin registry absolute source URI. Packaging now strips Mach-O debug/local symbols before ad-hoc signing. The desktop build wrapper temporarily gives the generated registry a stable package URI, restores the normal package configuration afterwards and stores diagnostic symbols outside the app. Windows packaging omits PDB/ILK files. CI audits all three archives and runs isolated fresh-start checks; publication depends on those checks.

## Previously local application fixes reviewed for this patch

- TLS profile trust selection, bounded public-CA loading, sandbox bookmark persistence, additive database migration and import/reopen preservation. Tests check both trusted and rejected-untrusted TLS calls. No test CA becomes a default trust root.
- Form/codec/workspace fixes for repeated row identity, bool-key maps, aliases/oneofs, offscreen invalid drafts, send/mode-switch validation, WKT strings, timestamp date/time/nanoseconds, explicit Value null and empty wrapper presence. Self-contained fixture and widget tests accompany the fixes. Cancel/half-close controls remain available when an unsent draft is invalid.

These previously uncommitted application changes are included in the 1.0.5 development patch after review and validation. Local server code, running processes, owner databases, test workspace exports and manual evidence remain outside the application repository. No Developer ID signing, Apple credential setup or notarization was performed; macOS uses the existing ad-hoc development packaging path.

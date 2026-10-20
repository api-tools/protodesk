# ProtoDesk roadmap

Source: [issue #15](https://github.com/api-tools/protodesk/issues/15). Verified against main `350f3bc` (v1.0.7). Planned items below are not shipped capabilities.

## Progress evidence

- Phases 0–1: shipped in [v1.0.8](https://github.com/api-tools/protodesk/releases/tag/v1.0.8), reviewed [PR #16](https://github.com/api-tools/protodesk/pull/16), commit `fe4f859`. Documentation/version alignment, strict PEM mTLS, explicit SNI and independent reflection metadata are implemented.
- Evidence: 143 local Flutter tests, 13 packaging tests, formatter/analyzer and required three-platform PR/exact-tag CI passed. Native synthetic macOS mTLS reflection/RPC and minimum-window editor verified. Consistent private database copy retained every original field/row in all four user tables. Production macOS: Apple Accepted, stapled, extracted signature/Gatekeeper/RPC/fresh-source checks passed. Checksums/source/notarization evidence are release assets.
- Native external picker completion was not claimed because another desktop workflow took input focus; automated picker/bookmark lifecycle tests passed.
- Phase 2: shipped in [v1.0.9](https://github.com/api-tools/protodesk/releases/tag/v1.0.9), reviewed [PR #17](https://github.com/api-tools/protodesk/pull/17), commit `3ee168a`. Recipient-bound OS-store references (including CA/SNI/authority), explicit literal migration, safe export/diagnostic choices and authenticated GitHub acquisition preserve offline caches. See [credentials](CREDENTIALS.md).
- Phase 2 evidence: 160 Flutter tests, 13 distribution tests, formatter/analyzer and required three-platform PR/exact-tag CI passed. Compiled reflection/local-schema RPC, safe/full transfer, fresh-start/restart and native Keychain write/read/verified deletion passed. Native source/credential surfaces inspected at 1000 × 650; manual native text-entry migration is not claimed, while widget tests passed. A private copy retained every original field/row in all four existing user tables. Production macOS: Apple Accepted submission `40cb8349-911e-496f-b757-5c2545cc1adf`, stapled, strict signature/Gatekeeper/extracted checks passed. All three archives audited and all six uploaded assets downloaded/verified.
- Phase 3: merged through [PR #18](https://github.com/api-tools/protodesk/pull/18), commit `89e6a87`; shipped in [v1.0.10](https://github.com/api-tools/protodesk/releases/tag/v1.0.10). Literal-only POSIX/modern PowerShell import, safe/full offline export, separate header contexts, TLS references, explicit authority and persisted call options are covered in [command interchange](GRPCURL_INTERCHANGE.md). Unsupported interactive sequences and independent SNI/authority combinations fail explicitly. Upstream grpcurl semantics reviewed at `1bac0f73832fa58af6af5c4c19a581886e1fe7a0`.
- Phase 3 local evidence: 193 Flutter tests passed (one optional CLI test skipped in the standard suite), plus the opt-in installed grpcurl/local mTLS/POSIX execution test and 13 distribution tests. Formatter/analyzer passed. Native populated safe/full export and shell switching inspected at 1000 × 650; native text-entry import is not claimed. Compiled reflection/local-schema four-mode RPC, fresh-start/restart and command/bundled-compiler smoke checks passed. A private database copy retained all original rows/fields in the four existing tables. Required three-platform review CI passed on `783f7da`. Exact-tag CI passed on all three platforms. Production macOS Apple Accepted `95ddd24a-31d3-469a-a170-e03c01d6d687`, stapled/signature/Gatekeeper/extracted checks and all six uploaded asset download/hash checks passed.
- Phase 4: shipped through [PR #19](https://github.com/api-tools/protodesk/pull/19), commit `e0897ef`, in [v1.0.11](https://github.com/api-tools/protodesk/releases/tag/v1.0.11). Bounded payload-free timelines, protobuf size/timing counters, explicit half-close/cancellation requests and descriptor-aware structured status are covered in [call diagnostics](CALL_DIAGNOSTICS.md).
- Phase 4 evidence: 199 Flutter tests, 13 distribution tests, formatter/analyzer, required three-platform review/exact-tag CI and native populated 1000 × 650 checks passed. Compiled four-mode reflection/local-schema diagnostics, isolated fresh/restart, command/compiler and native Keychain checks passed. Apple Accepted `08f1936e-4fb4-47de-98e6-6d82477df426`, stapled, strict signatures/universal architectures and extracted Gatekeeper verified. All three archives audited and all six uploaded assets downloaded/byte/hash verified.
- Phase 5a: request drafts/last-sent state, SQL history filtering/pagination and guarded app shortcuts shipped through [PR #20](https://github.com/api-tools/protodesk/pull/20), commit `2ddf44b`, in [v1.0.12](https://github.com/api-tools/protodesk/releases/tag/v1.0.12). See [request workflow](REQUEST_WORKFLOW.md). 206 Flutter tests, formatter/analyzer, macOS build, compiled four-mode draft/history-query checks, fresh/restart and 13 distribution tests passed. Final native accessibility labels and shortened dates were rechecked. Required three-platform review/exact-tag CI passed. Apple Accepted `67ad0502-419d-4bf7-ac74-e767c154039f`; stapled, extracted signature/Gatekeeper checks passed. All three archives audited and all six uploaded assets downloaded/verified. A private database-copy migration retained every original field/row in all four user tables, with an empty new draft table. Native nested draft and bidirectional queue restoration, schema-change warning and history pages beyond 100 calls inspected at 1000 × 650; date labels shortened after visual inspection.
- Phase 5b: named environments, bounded typed substitution, ordered RPC metadata presets and reusable source templates are implemented locally; not shipped. See [request preparation](REQUEST_PREPARATION.md). 226 Flutter tests, separately enabled installed-grpcurl test, formatter/analyzer, macOS build, 13 distribution tests and compiled AOT preparation/four-mode RPC/fresh-start checks passed. A private database copy retained every original field/row in the four user tables, with an empty new template table. Native synthetic nested RPC and prepared metadata inspected at 1000 × 650; source placeholders retained and preparation made no call. Review and platform CI remain delivery gates.
- Phase 6: explicit manual stable-release checks are implemented locally; not shipped. See [release availability and Windows signing assessment](RELEASE_AVAILABILITY.md). No background checks, installer execution or automatic binary downloads. Official fixed-endpoint metadata and exact repository/tag links are bounded and cancellable; notes render as plain text. Eight mocked regressions include unsafe links, redirects, limits, cancellation/disposal, semantic versions and minimum-size About layout. Native explicit GitHub check and populated result inspected at 1000 × 650. Full suite: 234 passed, one optional CLI test skipped; analyzer/formatter clean. Desktop/platform/release gates still apply. Windows signing is evaluated separately; no Windows certificate/account was provided and artifacts remain explicitly unsigned.
- Owner private endpoint: not tested.

## Baseline and scope

Source review of ProtoDesk main at `350f3bc` (v1.0.7) and Wombat at `e1bcd80dc7540fa4e2dce37e82e876e24bbc1200`. This is a static feature and architecture comparison, not a new end-to-end validation of every feature. Assume the current product works; preserve approved UI and all four existing RPC modes.

At review time the repository had no open issues and no dedicated roadmap document. This issue establishes the next implementation sequence. Do not redo completed streaming, proto imports, JSON viewer or Apple distribution work.

## Existing capabilities

ProtoDesk already contains unary, server/client/bidirectional streaming, explicit half-close, cancellation/deadlines, partial-result retention, reflection v1/v1alpha, local proto files and import roots, well-known types, Form/JSON editing, response search, headers/trailers, TLS server verification with custom CA, authority overrides, saved servers, collections, history and workspace transfer.

It also has public GitHub schema sources, offline validated source caching, queued/persisted streaming sequences and clean fresh installs. These should not be listed as missing.

## Confirmed differences from Wombat

| Capability | Wombat evidence | ProtoDesk evidence / gap |
| --- | --- | --- |
| mTLS client identity | internal/app/client.go loads Clientcert/Clientkey with tls.X509KeyPair | engine.dart/configuration and Servers UI support server CA trust only; no client certificate/private key |
| Separate reflection metadata | GetReflectMetadata and loadProtoFiles in internal/app/api.go; WorkspaceOptionsMetadata.svelte | one server metadata map is used for both discovery and application calls |
| grpcurl import/export | ExportCommands / ImportCommand in internal/app/api.go and grpcurl.go | no equivalent command interchange |
| Detailed per-call events/statistics | statsHandler.HandleRPC and frontend/src/views/Statistics.svelte | status, duration and message counts exist, but no corresponding per-message timings/size/event view |
| Last sent request per server/method | GetRawMessageState and setMessage in internal/app/api.go | selectMethod resets body to {}; reuse requires history/collections |
| Release availability notice | checkForUpdate and Updater.svelte | no application update discovery |
| Diagnostic insecure TLS option | client.go exposes InsecureSkipVerify | intentionally absent; do not equate this with normal TLS support being absent |

Wombat workspaces largely organize connection profiles; ProtoDesk servers already provide much of that workflow. True isolated project workspaces are an optional product extension, not a blocker for basic parity.

Do not copy Wombat blindly: its command import ignores several parsed flags, its command export interpolates request/header text into shell quotes, and reflection code prints metadata values. Implement safe semantics instead.

## Ordered implementation

### Phase 0 — Align documentation with shipped software

- Update README downloads to the current production release and explain signed/notarized macOS versus explicitly unsigned development packages.
- Remove outdated statements that Apple signing is still deferred.
- Correct Workspace transfer dialog's Version 1 description to match current version 2 exports and version 1/2 imports.
- Add docs/ROADMAP.md from this issue, keeping implemented items distinct from planned work.

### Phase 1 — Enterprise connection compatibility

- Add optional PEM client certificate chain and matching private-key references to a server profile for mTLS.
- Use the same identity and trust configuration for the initial probe, reflection, normal RPCs and authority override channels.
- Retain certificate verification. Distinguish CA trust, client identity, server name/SNI and HTTP/2 authority; do not introduce a global bypass.
- Validate missing/mismatched/malformed credentials and present actionable errors without exposing key material.
- Preserve sandbox file access/bookmarks on macOS; do not persist private-key contents or passwords into SQLite, history or workspace exports.
- If encrypted keys are supported, use a secure credential-store integration; otherwise explicitly reject them with a clear supported-scope message.
- Separate reflection metadata from RPC metadata, with an explicit backward-compatible inheritance policy for existing profiles.
- Add migration/import/export tests and real local mTLS integration tests: required identity accepted, missing/untrusted identity rejected, custom CA, reflection and local-schema paths, authority behavior and reconnect.

### Phase 2 — Secret handling and private schema repositories

This phase extends both products' practical workflow; it is not claimed as a Wombat parity gap.

- Introduce OS credential-store references for sensitive metadata and repository credentials.
- Provide safe exports/diagnostic copies with explicit inclusion choices; do not silently export reusable tokens.
- Clearly distinguish existing stored literals from new secret references and offer explicit migration without deleting working credentials.
- Add authenticated private GitHub proto sources using the existing RepositoryProvider seam.
- Limit token transmission to validated intended hosts and redirects, redact logs/errors, and preserve cache integrity/offline operation.
- Do not execute repository code or replace the bounded source validation path with an unrestricted clone.
- Validate credential lock/unavailability/revocation, authenticated fetch, cache recovery and import/export without secrets.

### Phase 3 — Reproducible requests through grpcurl

- Export a supported, documented subset of grpcurl commands including endpoint, method, JSON, proto/import paths, TLS/identity references, authority, deadlines, reflection headers and RPC headers.
- Correct shell quoting for POSIX and PowerShell; never embed private keys. Clearly indicate secrets in clipboard output and provide a redacted variant.
- Parse imports without invoking a shell. Preserve supported options and reject/report unsupported flags instead of silently ignoring them.
- Start with unary and server-stream requests; explicitly document what is and is not expressible for interactive client/bidirectional sequences.
- Test quotes, newlines, colons in metadata values, Unicode, paths with spaces, unsafe shell syntax and supported round trips.

### Phase 4 — Diagnostics without cluttering JSON responses

- Add an optional secondary diagnostics surface rather than expanding the main footer or response properties UI.
- Show sent/received message timestamps and counts, time to first response, total duration, serialized protobuf byte counts, cancellation and half-close events.
- Decode structured google.rpc.Status details when descriptors are available, while preserving raw status/trailers and unknown details.
- Label serialized protobuf bytes separately from compressed/network bytes; do not invent transport metrics unavailable from the runtime.
- Bound memory/log size and redact secret metadata. Preserve partial events/results on failure.
- Avoid automatic retries of non-idempotent RPCs and streams.
- Test unary, all streaming modes, early/partial errors, deadlines and cancellation.

### Phase 5 — Everyday workflow

- Restore last request state per server/method and preserve unsent drafts when switching methods; handle schema changes explicitly.
- Search/filter/paginate history by server, method, status and time. Current UI shows only the latest 100 calls and loads rows before truncation; query history with SQL limits/pagination.
- Add useful keyboard shortcuts (invoke/cancel, search, Form/JSON) without overriding ordinary editor shortcuts.
- Later add named environments/variable substitution and reusable metadata presets, with clear precedence and secret references.
- Keep this separate from isolated multi-project workspace design.

### Phase 6 — Distribution convenience

- Add a manual Check for updates action with version, release notes and official download link; optional background checks should be explicit.
- Do not claim a release-notification feature is an automatic updater or execute downloaded binaries.
- Evaluate Windows signing separately; the published Windows artifacts are currently unsigned.

## Optional / deferred

- Insecure TLS diagnostic bypass: only if a real development workflow requires it, explicit per-profile/session UI and clear indicator; never silently enable.
- Isolated named project workspaces, schema-change request compatibility checks, descriptor-set imports, protobuf editions/extensions and richer protobuf conformance: scope separately with concrete fixtures and measured support.
- REST, GraphQL, cloud collaboration, subscriptions and full auto-update installation are not part of this roadmap.

## Delivery policy

Implement phases sequentially with reviewable increments. Run relevant automated tests and actual desktop checks for changed workflows, preserve data/migrations, update this issue and docs/ROADMAP.md with evidence, and keep all communication in English. Existing Apple signing configuration should be reused for production releases; credential preparation must not block unrelated implementation.

Do not claim the owner's private endpoint was tested unless it actually was. Publish production artifacts only from matching tagged source after required CI and platform signing/notarization checks. This issue is an implementation backlog, not evidence that the planned features are already shipped.


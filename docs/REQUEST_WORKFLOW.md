# Request drafts, history and shortcuts

Request state is saved locally per server identifier and full method path. Switching methods restores its JSON (including invalid JSON), request metadata/OS-store references, timeout, authority, unsent queue and last sent snapshots. Switching to a method without a stored draft retains the existing request-metadata/call-option inheritance behavior. No draft resolves an OS credential, connects or invokes automatically. Metadata & call options offers **Load last sent request/sequence** when available; it validates against current descriptors before explicitly replacing the draft/queue and never invokes.

Drafts are debounced for 350 ms and flushed before method/server changes, backgrounding and normal desktop exit. Abrupt process termination within that interval can lose the most recent edit. Form fields commit to the request model only when valid; invalid transient Form text blocks method switching until repaired. Use JSON for a persisted incomplete JSON draft. A schema fingerprint change shows an explicit warning; original JSON/sequences remain available and existing schema validation blocks incompatible RPC input. No automatic field deletion or coercion occurs.

An additive `request_drafts` table contains version-1 state, capped at 64 MiB per draft. Existing database backups occur before migration. Unsupported versions/unknown fields or invalid protected-reference configurations remain intact and do not prevent startup. Their recovery warning blocks automatic replacement; inspect/recover the original local record rather than silently dropping future data. Drafts are local working state, excluded from workspace exports and release bundles. Existing saved requests/history remain unchanged; normal upgrades never reset databases.

History uses parameterized SQL with 50-row pages, a 200-row API cap and deterministic creation-time/identifier ordering. Search matches server name/address or full method literally (including `%`, `_` and quotes). Independent server/status and UTC date filters are available. Dates include the entire selected final day. Search/filter changes reset pagination; previous/next buttons expose older calls without loading the entire history. Listing selects lightweight summary columns; request/response blobs are fetched lazily for an individual record when preview/reuse needs them. Existing preview, reuse, collection save, individual delete and clear-history actions remain available.

App shortcuts use **Command on macOS** or **Control on Windows/Linux** (both modifiers are accepted):

| Shortcut | Action |
| --- | --- |
| Command/Control + Enter | Invoke/start, preserving Form/JSON validation |
| Command/Control + period | Cancel the active call |
| Command/Control + Alt + F | Focus service/method search |
| Command/Control + Alt + J | Toggle Form/JSON with the same validation as the footer |

Shortcuts are disabled behind modal routes. Ordinary text entry, copy/paste/undo, editor search conventions and Tab traversal retain their normal behavior. No Escape binding steals dialog/editor dismissal.

Verification uses isolated databases: clean initial state, restart, per-method/server drafts, invalid/future versions, schema-change warnings, queued/sent sequences, bounded deterministic pages and literal/combined/date filters. Widget tests exercise real key events, modal guards, search/mode controls and a 650-pixel history dialog with repeated open/close operations. Compiled four-mode release smoke checks draft restart and SQL history queries as well as existing RPC/transfer behavior.

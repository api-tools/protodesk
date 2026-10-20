# grpcurl command interchange

Open the terminal icon in the top management toolbar. This secondary dialog imports or exports a documented subset of grpcurl invocation configuration. ProtoDesk never runs a shell, grpcurl, a repository script or an imported command. It does not install or bundle grpcurl. A separate CLI installation is needed only if you choose to run a copied command yourself.

## Export

Select a unary or server-stream method and prepare the request in Form or JSON. Open **grpcurl import / export**, choose POSIX or **PowerShell 7.3+**, and click Generate. The default preview omits request JSON and every metadata value; its body placeholder is intentionally invalid JSON, and importing placeholders is rejected. It is a review template, not a complete runnable request.

Use the three explicit inclusion choices for request JSON, stored literal headers and OS-protected headers. Protected values are read only when their inclusion is selected. Included values may be reusable credentials or company payloads. Review the preview and its warnings before copying it elsewhere. Unchecking choices or changing shell/source mode clears the previous preview; Copy remains disabled until regeneration completes. File references never embed private keys. Repository PATs are never resolved for command export.

Schema choices are configured sources, reflection only, or local/cached definitions only. Local definitions use the bundled compiler; local-only export verifies the selected method and, when included, request compatibility. Git files must already exist in a validated commit cache. Export never fetches a repository. Missing/corrupted cache, permissions and invalid sources are recoverable errors; validate or grant access in Servers first. Only selected entry points and independent import roots become `-proto` / `-import-path` flags, not every dependency as an entry point. Paths must exist on the computer running the command; caches/source bytes are not embedded.

Interactive client/bidirectional request sequences are explicitly unsupported by interchange. Existing ProtoDesk streaming, queue/replay, half-close, cancellation and persistence remain available. No automatic retries or RPC invocation occurs here.

## Import

Choose the shell syntax, paste one command, then Parse and review. Parsing runs off the UI isolate and performs no file/network I/O. Review endpoint, TLS, method, file/root/header counts and warnings. Choose a server name and an existing collection or a new collection name. Choose the command's working directory with the native folder picker when needed for relative paths. On macOS that selection retains its security-scoped bookmark; absolute paths may still need explicit picker grants in Servers.

**Import server and saved request** creates a new server and request transactionally, appending to the chosen collection or creating the explicitly named collection. Existing records are not overwritten. It loads the request draft but does not connect or invoke. Connect explicitly to resolve the method; Invoke is a separate action. If the resolved method uses request streaming, a warning explains that interactive input requires ProtoDesk's Send/Finish controls rather than implying a complete CLI sequence was imported.

Relative entry names resolve through configured import roots in order, then the selected working directory. Relative escapes, unsafe selected symlinks, resolved entries outside a root, UNC/network paths and foreign Windows paths on another OS are rejected. No source contents are uploaded. Schema validation remains explicit in Servers or during Connect; command path resolution alone does not establish schema validity. Client certificate/CA/key paths are references and are validated when connecting; no key/password is read by the command parser.

Imported metadata is visibly treated as **stored literals**. Use the explicit protected-header migration controls in Servers or request metadata to move sensitive values into the OS store. This import does not silently create credentials or delete working literals.

## Supported semantics

| Configuration | Supported flags / behavior |
| --- | --- |
| Target / method | One explicit host:port, including IPv6; `package.Service/Method` with optional leading slash |
| Request | `-d` with one literal Protobuf JSON value; empty optional strings, nested messages, null and well-known JSON forms are retained without rewriting the body |
| Headers | Repeated `-H` for both contexts; `-rpc-header` / `-reflect-header` for separate contexts; split at the first colon and normalize names case-insensitively |
| Binary headers | grpcurl's base64/raw-input interpretation is converted to Dart's wire-base64 representation; padding differences preserve decoded bytes. Invalid existing wire-base64 cannot be faithfully exported and is reported |
| TLS | Verified TLS by default; `-plaintext`; `-cacert`, paired `-cert` / `-key` file references |
| Host overrides | `-authority`, `-servername`; import retains grpcurl's shared HTTP authority and derived TLS host through explicit profile fields |
| Deadline | Positive `-max-time` with millisecond precision, up to 24 hours; absence retains the current ProtoDesk RPC timeout and is reported |
| Schema | Repeated `-proto`, repeated `-import-path`, `-use-reflection[=true/false]` |
| Quoting | Literal POSIX single/double quoting and escapes; literal modern PowerShell quotes/backtick escapes; explicit line continuations |

Repeated effective header names are rejected because grpcurl represents multiple values whereas ProtoDesk's metadata map represents one value per name/context. Duplicate scalar flags, invalid/missing values and unsupported flags fail before any records change. A header name/value cannot contain prohibited control characters. A command is bounded to 4 MiB and 4096 arguments; schema and metadata resource limits still apply.

Unsupported inputs include shell expansion/variables and unquoted home-directory expansion, command substitution, operators, pipelines/redirection, globs, scripts/PowerShell script blocks, shell prefixes, stdin/file request bodies, text-format bodies, discovery verbs, Unix sockets, descriptor-set flags, insecure TLS, unlimited deadlines and other flags not listed above. Parser errors exclude request/body/header values; source validation retains its normal local path/compiler diagnostics. Empty `-d` omission produces a warning: the `{}` draft is an ordinary empty message and may need a well-known-type JSON form.

The parser does not emulate an entire shell. Prefer the generated single-quoted syntax for literal data. PowerShell output targets 7.3+ with Standard/Windows native argument passing, **not** Windows PowerShell 5.1 or Legacy mode; older native argument marshaling can remove embedded quotes. See Microsoft's [native argument-passing documentation](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_parsing?view=powershell-7.5#passing-arguments-that-contain-quote-characters).

## Important differences and routing

Upstream behavior was checked against [grpcurl commit 1bac0f7](https://github.com/fullstorydev/grpcurl/blob/1bac0f73832fa58af6af5c4c19a581886e1fe7a0/cmd/grpcurl/grpcurl.go). Both grpcurl host-override flags use a shared authority; differing values are rejected upstream. ProtoDesk can separate SNI from HTTP/2 authority and apply a call-only authority override. Export rejects combinations that grpcurl cannot express faithfully, including different reflection/RPC authority routing, without changing the profile. Choose local definitions without reflection when appropriate.

The server's **Server authority (HTTP/2)** applies to discovery and default RPCs. Blank preserves legacy behavior. Call options can override RPC authority only; TLS SNI remains explicit. Import fills the server-wide authority and TLS host so reflection and RPC routing match the CLI. Default HTTPS-port authority formatting is also emitted explicitly. Existing credential references remain bound to their effective recipient; changing that recipient requires rebinding/reconnection.

`grpcurl -max-time` covers connection/discovery as well as the call. ProtoDesk applies its RPC timeout after Connect; this difference is shown, not silently equated. When both local definitions and reflection are enabled, grpcurl combines descriptor sources while ProtoDesk prefers reflection and falls back to configured sources; the preview/import warns about that distinction.

## Persistence and verification

Additive migrations introduce `servers.http_authority` and version-1 `request_options_json` on saved requests/history. Existing data is backed up before changes. Missing legacy options preserve existing load behavior, and unknown option versions fail recoverably without erasing the record. Workspace version-2 safe/full exports retain options; version-1 imports still work. Saved-request editors expose timeout and authority controls.

Tests cover literal quoting/Unicode/newlines/colons, unsupported flags/unsafe syntax, binary metadata normalization, redaction/no credential reads, import-root selection and symlink/escape checks, offline cache use, saved options/migration, dialog cancellation/disposal and imported local mTLS reflection/RPC routing. Standard CI does not require grpcurl or a live external endpoint.

An optional local interoperability check uses an already-installed developer CLI and only a synthetic loopback mTLS fixture:

```sh
GRPCURL="$(command -v grpcurl)" flutter test test/grpcurl_cli_interop_test.dart
```

It verifies generated argv, actual POSIX quoting on macOS, binary metadata payload equivalence and separate discovery/RPC headers. PowerShell literal parsing/round trips are automated; this is not a claim of a native PowerShell session on macOS or verification of the owner's private endpoint.

## Manual macOS check

1. Build/run with the existing Flutter SDK: `python3 tool/build_desktop.py macos`, then launch the built app, or use `flutter run -d macos`. Use isolated storage under `~/Library/Application Support/ProtoDesk/` if desired; never delete an existing database.
2. Connect to a known local test server, select a unary method and populate nested Form/JSON fields and request metadata. Save/reuse a request with a nondefault timeout/authority.
3. Open the terminal icon at 1000 × 650. Generate the safe preview; verify payload/header values are omitted and warnings/actions remain reachable. Change shell and inclusion choices; the old preview must clear before regeneration. Generate full synthetic data and inspect quoting, not production tokens.
4. Import a supported synthetic command, review its fields and choose a collection. Confirm no connection/call occurs until explicit Connect/Invoke. Reopen its saved request and verify JSON, timeout, authority, local entry points and roots persist.
5. Try an unsupported flag, shell operator, redacted placeholder, mismatched SNI/authority, missing local grant and relative path escape. Confirm actionable errors and unchanged saved data. Close while parsing/choosing a directory/generating and reopen; no controller/unmounted-widget assertions should occur.

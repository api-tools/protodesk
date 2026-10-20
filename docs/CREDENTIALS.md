# Protected credentials and private schema repositories

## Storage and recipient binding

Sensitive metadata and GitHub PATs can be stored in the OS credential store. SQLite contains labels, lifecycle states, opaque UUID references and recipient descriptions. It never contains the protected payload. Credential values are resolved only for explicit credential creation or a connection, RPC or repository fetch that needs them. Starting the app, browsing labels and using a validated offline repository cache do not read the OS store.

macOS uses the login Keychain through `flutter_secure_storage`, with data-protection Keychain disabled so the existing Developer ID/sandbox policy does not require a shared Keychain entitlement or provisioning profile. Windows uses the plugin's OS-backed credential storage; Linux requires libsecret and a running Secret Service (for example GNOME Keyring or KWallet's Secret Service integration). If the store is locked, unavailable or access is denied, the operation fails with a recoverable error. There is no plaintext fallback. Windows/Linux native behavior is checked by their desktop builds and mock-backed regression tests; macOS additionally has a compiled native write/read/delete smoke check.

Metadata credentials are bound inside the protected payload to endpoint, TLS policy, custom CA file reference, effective TLS name/SNI and HTTP/2 authority. Changing any recipient setting requires rebinding; changing a connected profile requires reconnection before another RPC; changing workspace JSON cannot silently send an existing protected value to another recipient. Repository credentials are bound to a specific GitHub owner/repository API path. Values cannot contain control characters, and PATs must be ASCII without whitespace. Private-key passwords and encrypted PEM keys remain unsupported.

## Headers and migration

Servers → Create/Edit provides separate protected RPC and reflection headers. Enter a header name, then **Store securely** to create a protected value or choose an existing credential bound to this recipient. If the literal JSON already contains that header, the creation dialog is prefilled for explicit migration. The literal is removed from the edited form only after a verified OS write succeeds. Save the server to persist the reference. Cancelling the server dialog preserves the original saved literal; the new credential remains listed under **Manage protected credentials**, where it can be deleted. No automatic migration or database wipe occurs. Existing SQLite backups may still contain previously stored literals.

Blank reflection JSON inherits RPC literals and protected RPC references. Explicit reflection JSON (including `{}`) replaces that inheritance. Protected reflection references overlay the chosen reflection metadata only and never enter application RPCs. With reflection disabled, its credentials are not resolved.

For application calls, precedence is server literals → protected server headers → request literals → protected request headers. Header names are compared case-insensitively. A request literal explicitly overrides the same server reference, so an unused protected value need not be read. Request-specific protected headers are configured under Metadata & call options. Call authority overrides must match the credential's binding; create a request-specific credential with that authority when needed.

New history entries contain literal headers and references separately, never resolved protected header values. Replay resolves the reference again. Existing history and literal configurations are preserved. Request/response bodies are user data and are not recursively scrubbed; a server can return sensitive content in its payload. Known transmitted header values are removed from error text before it enters status/history. Response headers/trailers stay inspectable in memory.

Removing a header/source reference does not delete a shared OS credential. **Manage protected credentials** deletes only credentials catalogued in this workspace, confirms deletion through a read, and retains the catalog entry if deletion fails. Interrupted writes remain pending/unavailable for recovery instead of disappearing. The app never enumerates unrelated OS credentials.

## Private GitHub sources

In the source manager add a Git repository, enter `https://github.com/owner/repository`, reference, proto directory and import roots, then choose **Set / replace GitHub token**. Use a fine-grained PAT with repository Contents read access. Public sources continue to work anonymously. ProtoDesk does not use `gh`, environment tokens, external Git or repository scripts.

The protected token is attached only to requests to `https://api.github.com/repos/owner/repository/…`. GitHub's archive API returns a short-lived signed codeload URL. The archive is fetched with a separate request and **no Authorization header**. Only the expected HTTPS `codeload.github.com/owner/repository/legacy.zip/commit` redirect is allowed, with no further redirects. Fixed hosts, public IPv4 DNS checks, pinned connections, TLS verification, direct networking, deadlines and existing archive/file/disk limits remain enforced. Errors exclude tokens, signed URLs and remote response bodies.

Validated commit caches still work offline without opening the credential store. Refresh requires current credentials and network access; failed authorization/download leaves the previous cache intact. No owner private endpoint or private repository is assumed tested by mocked integration tests.

## Safe transfer and diagnostic copies

Workspace exports omit literal metadata and request bodies/streaming sequences by default. Header names are retained as **unbound references**, requiring a real credential to be selected before use. Protected values are never read or exported. References may work on the same computer; other computers require rebinding. Explicit checkboxes allow inclusion of stored literals/source extensions and request bodies. Those choices can expose reusable tokens or company payloads, so review the destination and file contents. Unknown source extensions cannot be safely guessed and require explicit literal inclusion rather than silent field deletion. Git caches are never embedded.

Imports still accept workspace versions 1 and 2 and create new records. This additive migration introduces a credential catalog and reference columns, backs up existing databases before changes, and preserves existing identifiers, servers, collections, requests and history.

Response metadata offers **Copy redacted diagnostics**, which removes every metadata value, including custom authentication headers, and excludes request/response bodies. Complete response JSON copying remains unchanged. Full metadata copying is explicitly labelled sensitive.

## Local native store check

Build with `python3 tool/build_desktop.py macos`. Run `python3 tool/smoke_credentials.py build/macos/Build/Products/Release/ProtoDesk.app/Contents/MacOS/ProtoDesk`. The helper uses a new, empty path under the application support directory and runs the compiled executable with `PROTODESK_DATA_DIR` pointing there and `PROTODESK_SMOKE_CREDENTIALS=1`. This explicit developer path creates, reads and deletes only a synthetic credential in an empty catalog, reports pass/fail without values and exits. It refuses existing database files and retains the isolated recovery catalog if the check fails. It is not run automatically on startup or in CI environments without an OS credential service.

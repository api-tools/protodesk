# Connection security and discovery metadata

## Server trust and client identity

In Servers → Create/Edit server, enable TLS. System trust roots are the default; Choose CA certificate selects an optional PEM trust bundle. Certificate verification stays enabled. A private CA is not a client identity.

For mutual TLS, select both **client certificate** (PEM leaf and optional intermediate chain) and **client private key** (matching, unencrypted PEM). RSA and P-256 identities are covered by local integration tests. Encrypted keys, binary containers and passwords are explicitly unsupported in this increment. No external openssl program is required by the app. Regeneration of public development fixtures uses a developer-only OpenSSL script.

Only file references are stored in SQLite/workspace exports. Key bytes remain in connection memory and are not added to history or logs. Safe workspace exports omit literal metadata by default; explicit inclusion can still disclose existing literals. Protected OS-store values are never exported. See [credentials](CREDENTIALS.md). Reselect certificate/key/CA files with the native picker on another computer. macOS retains security-scoped bookmarks; copying a path alone does not grant sandbox access. Missing, malformed, encrypted and mismatched files yield recoverable errors without key contents.

The TCP endpoint determines where the socket connects. **TLS server name / SNI** determines the verified certificate hostname when set. **Server authority (HTTP/2)** controls the default `:authority` for reflection and application calls; blank preserves the endpoint-derived default. The request's **authority override** affects application calls only. Explicitly configure the TLS server name to keep it independent of call authority. With a blank TLS server name, existing behavior is retained: the endpoint hostname is used for discovery, and a per-call authority override also supplies its legacy TLS name. No insecure certificate bypass exists.

The initial probe waits for the peer’s HTTP/2 SETTINGS (not just a locally completed TLS handshake), so TLS 1.3 client-certificate rejection cannot masquerade as a connected endpoint. No application RPC or keepalive PING is sent by the probe. One connector builds the probe, reflection channel, application channel and authority-override channels with the same trust and client identity. Reconnect reloads file references; channels within a connection use the same identity snapshot. Native PEM preflight runs off the UI isolate. A fresh-context parser retry handles a reproduced Dart native-error-queue recovery defect without changing bytes, bypassing certificate/key matching, or retrying RPCs.

## Reflection metadata

- **metadataJson** remains the server's application RPC metadata, merged with per-request overrides as before.
- Blank **Reflection metadata JSON** inherits that server metadata (backward-compatible default for old and new profiles).
- `{}` explicitly sends no reflection metadata.
- A nonempty JSON object supplies only those reflection headers. It never merges into application calls.

Reflection v1 and v1alpha share this policy. Offline schema validation does not require endpoint credentials or a connection.

## Persistence and validation evidence

The initial four additive text columns store client certificate/key references, TLS server name and reflection metadata JSON. Subsequent additive migrations retain protected metadata references/catalog, server-wide HTTP authority and versioned saved-request/history options. Each defaults to an empty string. Existing databases are backed up before initialization; no database reset or record replacement occurs. Existing IDs, metadata, collections, history and proto configurations remain intact. Workspace version 2 round-trips the new references; version 1 imports keep inheritance defaults. Unsupported fields are rejected rather than silently discarded.

`test/mtls_test.dart` uses an isolated loopback TLS server requiring trusted client certificates. It covers RSA chains/P-256, custom CA trust, reflection and local schemas, metadata isolation/inheritance, independent SNI/authority, wrong-name rejection, missing/untrusted identity rejection without application execution, reconnect and all four RPC modes. Migration/import/export and malformed-key recovery are covered. Dialog lifecycle tests cover late client picker and bookmark completions after cancellation. Test keys are public fixtures outside application assets; release audits reject credential files in bundles.

The owner's private endpoint has not been tested. Passing these local fixtures does not establish compatibility with that endpoint.

`test/grpcurl_integration_test.dart` additionally verifies imported mTLS commands against a local required-client-certificate server, including shared reflection/RPC authority, independent headers, persisted deadlines and no automatic invocation. See [command interchange](GRPCURL_INTERCHANGE.md).

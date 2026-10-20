# Named environments and reusable metadata presets

Open the toolbar's **Environments & metadata presets** action for the selected server. Definitions are local and belong to that server. They can be configured without connecting; preparing a request requires a selected method, including a method discovered from local schemas while offline.

## Explicit preview and apply

Preparation is an explicit operation. **Preview preparation** resolves a template off the UI thread, validates the result against the selected method and shows the proposed JSON and header names. It reads no credential values, opens no connection and invokes no RPC. **Apply prepared draft** materializes the reviewed result into the current JSON and RPC metadata. Existing queued and sent message snapshots stay unchanged.

Changing a definition never silently reinterprets a saved request, history entry, grpcurl import or active call. Runtime RPC behavior remains literal until preparation is explicitly applied. If the request, method, schema, recipient/call options or protected references change after preview, apply requires a new preview. Closing/cancelling abandons worker results; preparation is bounded and performs no background network operation.

The first apply can keep the original source as a reusable template, keyed by server/method. Choose **Saved reusable template** to prepare those original placeholders for another environment. A materialized current draft does not replace that source by default; replacement requires the explicit checkbox. **Load saved template into draft** restores its original JSON/metadata/references for editing or saving to a collection, without invoking.

Definitions and working templates have separate save behavior: **Save definitions** persists environment/preset configuration; Apply changes the request. Local working templates are excluded from workspace exports, like working drafts/history. To transfer a template, load it into the draft and save a collection request, then explicitly include request bodies when exporting. Definition values still follow the sensitive-literal export choice.

## Variable values and JSON semantics

An environment has a name and a JSON object of literal values:

```json
{"customer":"alice","count":0,"enabled":false,"settings":{},"nothing":null}
```

A whole JSON value placeholder keeps the variable's type:

```json
{"name":"${customer}","limit":"${count}","enabled":"${enabled}","settings":"${settings}","value":"${nothing}"}
```

Here the prepared `limit` is a JSON number, `enabled` a boolean, `settings` an object and `value` explicit null. Empty strings, false, zero, empty containers and null are not discarded or treated as missing. The existing ProtoJSON encoder remains authoritative for the selected field: for example ordinary null versus `google.protobuf.Value`, optional empty strings, wrappers and proto2 required fields retain their existing semantics.

Embedded scalar placeholders become text. Object/array variables require a whole JSON value placeholder. Header results are strings; scalar null in a header becomes the literal text `null`, never an omitted header. Variable names are case sensitive. Values resolve once; a variable containing `${another}` stays literal rather than recursively expanding. Escape `$${name}` to produce literal `${name}`. Malformed or missing/unbound placeholders fail before any draft changes.

Variables affect JSON values and literal request/preset headers only. JSON keys, endpoints, TLS/CA/client identity, SNI, HTTP authority, reflection configuration and protected credential values are not interpolated. There is no OS-environment lookup, shell expansion, script execution, file reading or source upload. Form preserves unresolved typed boolean/container/enum placeholders in raw JSON editors until preparation; valid empty/required-field editing remains available. JSON mode is useful for authoring templates.

## RPC metadata precedence and protected values

Select any presets in the Prepare tab. Reorder them with the small up/down controls; they apply top to bottom. The effective order is:

1. Existing server RPC defaults.
2. Selected presets in order; later values replace earlier values/references for the same case-insensitive name.
3. Existing request literal overrides, then existing request protected references.

Within a preset a protected reference overrides the same literal key. Overridden values are removed before variable lookup, so an unused placeholder cannot cause a spurious missing-variable error. Reflection metadata retains its separate configured behavior.

Use **Protected preset headers** to create/reuse recipient-bound OS-store references or explicitly migrate stored literals. Store complete sensitive header values in the OS store; environment values are ordinary local literals, not a secret manager. Preparation carries opaque references without reading them. Actual invocation uses the existing protected-payload recipient check before returning/sending a credential. A missing/unbound/wrong-recipient reference must be rebound; there is no plaintext fallback.

After a prior apply, current request overrides can intentionally win over newly selected presets. Use the saved original template when preparing another environment rather than expecting already materialized values to change automatically.

## Persistence, transfer and limits

Migration adds `servers.request_profiles_json` and a separate `request_templates` table, with version-1 representations. Existing backups run before schema changes; server IDs, collections, requests, history and credential catalogs are preserved. Fresh installations contain no definitions/templates or seeded user records. Version-1/2 workspaces remain accepted.

Safe exports omit literal environment/header values. Variables become explicitly **unbound**, distinct from a bound variable whose value is null; preset headers become unbound references. Full literal inclusion is an explicit export choice and never reads OS values. Unknown/corrupted definitions remain intact on startup and unrelated server/cache edits; safe export/preparation rejects them rather than guessing how to discard sensitive fields. Explicit full workspace export preserves the raw definition for recovery. Unsupported imports fail transactionally. Unknown local templates are preserved and cannot be silently replaced; current-draft preparation remains available without template replacement.

Limits: 4 MiB definitions, 32 environments and 32 presets, 256 variables per environment, 64 levels of JSON nesting, 4 MiB request templates, 16 MiB encoded metadata templates, 128 effective headers with 64 KiB per value, 32 MiB prepared JSON and 64 MiB local template state. Expansion checks the output budget while resolving, before constructing an oversized result. Preview text is truncated for large results; Apply uses the complete bounded result.

## Verification on macOS

1. Run `python3 tool/build_desktop.py macos` or `flutter run -d macos` with the installed Flutter SDK. Preserve your database; use an isolated test workspace when desired.
2. Select a local test method. Open the preparation action, add an environment containing empty strings, false, zero, null, nested objects and arrays, then add RPC presets. Save definitions and reopen them.
3. Author `${name}` values in JSON. Inspect typed placeholders in Form without a crash or hidden empty replacement, then choose an environment/presets and Preview. Verify no connection/call occurs. Apply and inspect correctly typed Form/JSON and request metadata.
4. Reopen, select Saved reusable template and a second environment. Verify the original placeholders prepare again, queued/sent snapshots remain unchanged and the source is not replaced unless explicitly selected. Load the source into the draft to edit/save it.
5. Test missing/unbound variables, invalid JSON/types, preset ordering and protected reference rebinding. Change call options after preview: Apply must require another preview. Close during preparation and reopen without lifecycle assertions.
6. At 1000 × 650 inspect tabs, scrollable editors, footer actions, long names and metadata. Verify safe/full workspace transfer and an empty fresh startup/restart.

Automated checks use mocked credential stores and isolated databases plus a real synthetic local RPC. They cover typed/well-known presence, safe/full transfer, malformed/future data, expansion limits, exact precedence, worker cancellation/disposal, reusable templates and ordinary Form regressions. Compiled desktop smoke exercises the standalone AOT worker, bundled compiler, optional-empty/null semantics and template persistence. No owner's private endpoint is implied by these checks.

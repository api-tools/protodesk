# ProtoDesk 1.0.4 development release

This tested development patch supports all four gRPC modes. macOS is **ad-hoc signed and not notarized**; Windows is unsigned. Developer ID signing and notarization are deferred to final distribution. This prerelease does not claim Apple trust and does not replace the production signing gate.

- Compact, right-aligned Form/JSON icons retain tooltips, keyboard focus, an active-state indicator and drafts/validation.
- Client and bidirectional streams support queued snapshots, live send/receive, explicit finish-sending, cancellation, deadlines and partial results. Response metadata is available while streams remain open.
- Saved stream sequences now replay with backpressure: sequences longer than the 64-message live queue can be reused without exceeding that queue. Full-stream limits remain 1,000 messages / 64 MiB. Replay preserves snapshot order and wakes when cancelled.
- Saved sequences and metadata survive database reopen, collection/history reuse and version 1 workspace import/export. Existing user data and the approved workspace layout are retained.

Validation: formatter/analyzer, 46 Flutter tests, 8 distribution-script tests, desktop release builds and compiled reflection/proto smoke for all four RPC modes on macOS, Windows and Linux.

## Run the downloaded bundle

- macOS: extract `ProtoDesk-macos-development.zip` and open `ProtoDesk.app`. Universal Intel/Apple Silicon; ad-hoc signed, not notarized. macOS may require explicit approval for this downloaded app. Do not disable Gatekeeper.
- Windows x64: extract the complete ZIP and run `protodesk.exe`; keep the DLLs/data beside it.
- Linux x64: extract the archive and run `bundle/protodesk`; GTK 3 and desktop system libraries are required.

No Flutter, Dart or protoc installation is needed. Verify downloaded files against `SHA256SUMS.txt`.

## Owner test checklist

1. Connect to an existing server and invoke unary and server-streaming methods.
2. Queue distinct messages for a client stream, Start, send another message, then Finish sending; inspect the response and metadata.
3. Start a bidirectional stream; confirm responses appear while sending remains open. Try cancellation and a short deadline and inspect retained partial results.
4. Save a streaming sequence, restart, reconnect and replay it from Collections or History. Export/import a collection and replay the imported request.
5. Switch Form/JSON with an invalid draft; confirm the draft/validation and pane resizing remain intact.

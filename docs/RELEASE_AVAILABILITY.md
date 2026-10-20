# Manual release availability

Open **About ProtoDesk → Check for updates**. Only an explicit check contacts the fixed official GitHub latest-release API. There are no startup/background checks, automatic binary downloads, silent installation or execution of downloaded files. No server address, request, schema, workspace data or credential is sent; GitHub necessarily receives the network request/IP address.

The secondary About surface shows the latest stable version, bounded plain-text notes, official release page, available platform downloads and checksums. Stable semantic versions are compared numerically, ignoring build numbers. Development/prerelease builds are not declared up to date. Links open the system browser only after a click; Copy official link is available if launching fails. The Windows link explicitly says unsigned.

The response has a 1 MiB streaming limit, a 15-second total deadline and cancellation on user request/dialog disposal. Redirects are refused. Release tags must be stable `vMAJOR.MINOR.PATCH`, the page must match this repository/tag exactly, and recognized download URLs must match this repository/tag/asset exactly. Notes are plain text; HTML, Markdown links and remote images are not executed or fetched. Starting a new check clears the earlier result, so failed/cancelled retries cannot display stale versions or links as current. Network/rate-limit/invalid-response failures are recoverable and do not modify user data. Opening an official browser link is not an in-app package/signature verification; verify release checksums and platform signatures before installation.

Implementation uses the official Flutter [url_launcher package](https://pub.dev/packages/url_launcher) for user-initiated HTTPS links, restricted by the validated release object. It never launches arbitrary schemes or shell commands. Tests mock the fixed-endpoint transport, not live GitHub. Production signing includes the new native plugin through the existing nested-code inventory.

## Windows signing assessment

Current Windows archives remain **unsigned**. Apple Developer ID credentials do not sign Windows executables. This roadmap requires a separate assessment, not an unapproved purchase or enrollment.

A future production Windows signing gate needs either a public-trust code-signing identity backed by a protected key/provider, or an approved managed signing account. Microsoft's [Artifact Signing](https://learn.microsoft.com/en-us/azure/artifact-signing/overview) requires an Azure subscription, identity validation and a certificate profile; eligibility and pricing must be checked during enrollment. No cost estimate or eligibility is assumed here. An alternative certificate provider similarly requires identity verification, secure key custody and a Windows-compatible signing integration.

CI should use a protected release environment with least-privilege/federated access where available, sign the application's owned PE code before ZIP creation, preserve/verify vendor signatures, apply an RFC 3161 timestamp and fail if verification fails. Microsoft's [SignTool](https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool) supports signing, timestamping and policy verification; use explicit SHA-256 file/timestamp digests and `signtool verify /pa /all /v` on the extracted release. Record signer/timestamp evidence alongside checksums. Signing does not guarantee SmartScreen reputation or warning-free first runs.

No Windows signing account/certificate was provided or configured in this task. Windows build/test/package CI remains enabled; unsigned status is visible in release notes and update UI. This is independent of the existing required Developer ID/Apple Accepted/stapled macOS production gate.

## Manual verification

1. Open About without clicking Check; confirm no update operation begins.
2. Click Check, verify the stable version/notes and matching official repository links. Resize to a narrow window and scroll the notes without overflowing the dialog.
3. Open the official release page, then test Copy official link. No installer runs in ProtoDesk.
4. Check offline/rate-limited conditions, retry and cancellation. Close About during a pending check and reopen: no stale result or lifecycle error should appear.
5. Run `flutter test test/release_check_test.dart`; mocked tests cover fixed HTTPS endpoint, no authorization, rejected redirects/unsafe URLs, size limits, total deadline, cancellation, versions and narrow-layout lifecycle behavior.

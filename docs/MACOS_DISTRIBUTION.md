# Developer ID distribution setup

The pipeline is prepared; successful Developer ID signing/notarization must be established locally before the first public signed release. The existing public macOS downloads remain ad-hoc releases until a verified replacement is published. No signing/notarization completion is claimed by this setup document.

## Local credentials — keep all secrets on your computer

1. In Xcode → Settings → Accounts, select your paid Apple Developer team → Manage Certificates → **+ → Developer ID Application**. Select the team with membership Team ID `ZGPYL87DRA` if it is the intended distribution team; verify this in Apple Developer account → Membership details. A Developer ID Application certificate must include its private key in Keychain Access → My Certificates. **Apple Development**, Apple Distribution and Mac App Distribution are not substitutes. If this option is unavailable, the team Account Holder can create the certificate through Certificates, Identifiers & Profiles using a locally generated CSR and install the certificate on the computer holding that private key.
2. Confirm the identity locally:
   ```sh
   security find-identity -v -p codesigning
   ```
   Set the public Team ID in your terminal:
   ```sh
   export PROTODESK_TEAM_ID=ZGPYL87DRA
   ```
   If more than one Developer ID Application identity exists for this team, select its public SHA-1 fingerprint with `export PROTODESK_SIGNING_IDENTITY=FINGERPRINT`.
3. Create an app-specific password in your Apple Account. Store it using **interactive secure prompts**; do not put passwords in shell commands, chat, Git, environment files or issue comments:
   ```sh
   xcrun notarytool store-credentials protodesk-notary --team-id "$PROTODESK_TEAM_ID"
   ```
   Leave credential flags absent and enter your Apple ID and app-specific password when prompted. An App Store Connect API key can alternatively be stored in this profile using notarytool's interactive setup.
4. Verify readiness and run the local release:
   ```sh
   cd /path/to/protodesk
   python3 tool/package_macos.py check
   flutter build macos --release
   sh tool/package_macos.sh
   ```

Default packaging requires a valid Developer ID Application identity, expected team and usable `protodesk-notary` profile. It discovers every real Mach-O file and nested code bundle, signs inside-out with hardened runtime and secure timestamps, and assigns entitlements only to the app executable and protoc helper. Unexpected nested executables fail until an explicit entitlement policy is added. Framework symlinks are preserved.

The script verifies signatures/team/entitlements, submits an archive with `notarytool --wait`, reviews the notary log, staples the app, validates the ticket and Gatekeeper assessment, then creates the distribution ZIP. It extracts that ZIP and repeats signature/stapler/Gatekeeper checks plus the compiled reflection/proto/SQLite smoke tests. Output is `dist/release/ProtoDesk-macos-universal.zip` with a checksum-bound `macos-notarization.json`. No ad-hoc fallback is allowed. Notary JSON/logs are kept in `dist/release`; on timeout, use `notarytool info`, `wait` and `log` with the submission ID. Apple keeps processing timed-out submissions. Repair errors or review warnings before retrying the complete pipeline.

The app sandbox, selected-file access, security-scoped bookmarks, networking and narrow existing SQLite-directory access remain enabled. Library validation is not disabled. Windows signing is outside this workflow.

For development only:
```sh
python3 tool/package_macos.py development
```
This produces the distinct `dist/ProtoDesk-macos-development.zip`, is ad-hoc signed and is not a public signed release.

## GitHub Actions — configure only after local success

Use the repository environment **macos-release**, protected by a trusted reviewer and restricted to version tags `v*`. The signing job verifies that the tag commit belongs to `main`, depends on successful OS CI, and never runs for PRs. Do not use `pull_request_target` or put signing secrets in ordinary build jobs.

Exact environment secret names:

| Secret | Owner-supplied value |
| --- | --- |
| `APPLE_DEVELOPER_ID_P12_BASE64` | Base64 of the Developer ID Application certificate **and private key**, exported as password-protected `.p12` from Keychain Access |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | That export password |
| `APPLE_TEAM_ID` | Verified 10-character membership Team ID |
| `APPLE_NOTARY_APPLE_ID` | Your notarization Apple ID |
| `APPLE_NOTARY_APP_PASSWORD` | App-specific password for notarization |

Upload the certificate directly from a private local file:
```sh
base64 < /PRIVATE/PATH/DeveloperID.p12 | gh secret set APPLE_DEVELOPER_ID_P12_BASE64 --repo api-tools/protodesk --env macos-release
```
For each other secret, run `gh secret set SECRET_NAME --repo api-tools/protodesk --env macos-release` and paste its value into the local interactive prompt. Do not send these values to Codex. Inspect names only with `gh secret list --repo api-tools/protodesk --env macos-release`.

The runner imports credentials into a random-password temporary keychain, authorizes Apple signing tools, stores a validated notary profile there, removes the `.p12`, and restores its original keychain search list/deletes the temporary keychain in an `always()` cleanup step. Missing secrets, certificate mismatch, notary warnings/rejection, failed staple/Gatekeeper or final-artifact smoke failure prevent public release. Environment approval remains an owner action.

References: [Apple distribution signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/), [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [Developer ID](https://developer.apple.com/developer-id/).

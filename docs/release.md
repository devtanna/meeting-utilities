# Release procedure

## Today (development-signed test builds)
1. `scripts/test.sh`
2. `scripts/release.sh` → `dist/MeetingUtility-<version>-<build>-arm64.dmg`, `.zip`, `SHA256SUMS.txt`.
   The script verifies arm64, nested signatures, the MLX metallib inside the service, no MLX symbols in the host,
   and no model weights in the bundle.
3. Hand the DMG to testers with `docs/INSTALL-TESTERS.md` (also inside the DMG as "Read Me First").

## Blocked until an Apple Developer ID exists (open items)
- Developer ID signing with Hardened Runtime (set `MU_TEAM_ID`, `CODE_SIGN_IDENTITY = Developer ID Application`,
  `ENABLE_HARDENED_RUNTIME = YES` in `Config/Identity.xcconfig`).
- Notarization and stapling: `xcrun notarytool submit dist/*.dmg --keychain-profile <profile> --wait` then
  `xcrun stapler staple dist/*.dmg`; Gatekeeper check with `spctl -a -vv` on a clean account.
- Sparkle: generate keys once with Sparkle's `generate_keys` (private key stays in the maintainer's keychain, never in
  the repo), put the public key and HTTPS feed URL in `Identity.xcconfig`, then sign archives with `sign_update` and
  publish `appcast.xml` (`generate_appcast dist/`).
- Signed-upgrade test from a previously installed signed build, including a schema migration.

Signing keys and their recovery location must be recorded by the maintainer outside this repository.

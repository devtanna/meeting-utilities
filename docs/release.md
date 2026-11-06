# Release procedure

## Publishing a release

```sh
make publish                 # patch: 1.0.0 → 1.0.1
make publish BUMP=minor      # 1.0.1 → 1.1.0   (also: major, or an exact X.Y.Z)
make publish-dry BUMP=minor  # bump + test + build only; nothing is committed or pushed
make publish NOTES=notes.md  # your highlights above the auto-generated changelog
```

`scripts/publish.sh` checks that you are on a clean `main` in sync with GitHub and that `gh` is logged in. It then:
1. bumps `MU_VERSION` and `MU_BUILD` (+1) in `Config/Base.xcconfig`, the only place the version lives
2. runs `scripts/test.sh` and `scripts/release.sh`. That makes a fresh `dist/` with the DMG, zip and `SHA256SUMS.txt`,
   and verifies arm64, nested signatures, the MLX metallib inside the service only, and no model weights in the bundle
3. commits "Release vX.Y.Z", tags it, and pushes `main` and the tag
4. creates the GitHub release with the three files, install notes and generated release notes

If a step before the commit fails, the version bump is undone. If the GitHub release step fails after the push,
rerun only that step with `gh release create vX.Y.Z dist/*.dmg dist/*.zip dist/SHA256SUMS.txt`.

Builds are ad-hoc signed and not notarized, and users update manually from GitHub Releases (there's no Sparkle feed yet).

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

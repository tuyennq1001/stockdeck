# StockDeck GitHub release workflow

Use this checklist for each StockDeck release. The project has used a release branch and a separate PR back to `main` so the release tag stays attached to the release commit.

## Prepare and publish

1. Merge the feature/fix PR into `main` first, then update local `main` from `origin/main`.
2. Read the latest GitHub release and `StockDeck/Info.plist`; choose the next version and increment `CFBundleVersion` by one.
3. Create `release/v<version>` from the updated `main`, add `release-notes/<version>.html`, and push the branch with upstream tracking before running the release script:

   ```bash
   git switch -c release/vX.Y.Z
   git push -u origin release/vX.Y.Z
   ```

4. Run `./release.sh <version> <build_number>`. It builds and smoke-tests the app, signs/packages the ZIP, signs the Sparkle appcast item, commits and pushes release metadata, creates the GitHub Release, and attempts the Homebrew cask update.
5. Open a PR from `release/v<version>` to `main` and merge with a merge commit (`gh pr merge <number> --merge --delete-branch`). Do not squash: the GitHub release tag points at the release-branch commit.
6. Verify the published GitHub Release/tag, ZIP asset, appcast version/signature, SHA-256, and that `main` contains the release commit.

## Signing behavior on the current machine

- Sparkle's private signing key is available in Keychain and matches the public key already in `StockDeck/Info.plist`. Keep using the existing `sign_update` key; do not generate or replace it, or existing installs will reject the update feed.
- The `notarytool` Keychain profile is not configured. The current `release.sh` does not stop for that condition: if it finds no matching Developer ID identity, it signs with the available Apple Development identity and skips notarization/stapling. This fallback was used for v1.1.18 and v1.1.19; state this limitation when reporting the release.
- `release.sh` currently searches for an outdated Developer ID identity (Simone Ruggiero), while this machine's available Developer ID certificate is `Developer ID Application: RELIPA COMPANY LIMITED (B2U85XPU55)`. Unless the script is corrected and notarization credentials are configured, expect the Apple Development fallback above.
- The configured Homebrew cask path may not exist locally. If the script reports that, the GitHub release still succeeds; report the missing cask update and provide the ZIP SHA-256 for a later manual update.

## v1.1.19 example

- Version/build: `1.1.19` / `22`.
- Release branch commit: `6b91760`; release metadata PR: #186, merged with a merge commit.
- GitHub Release: <https://github.com/tuyennq1001/stockdeck/releases/tag/v1.1.19>.
- Signing used Apple Development and skipped notarization; Sparkle EdDSA signing succeeded. Homebrew cask was absent at the configured local path.

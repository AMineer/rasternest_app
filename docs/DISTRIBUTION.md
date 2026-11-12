# Distributing RasterNest

RasterNest ships outside the Mac App Store, as a DMG on your website or GitHub Releases plus Homebrew.

## 1. Signing and notarization (one-time setup)

People who download the DMG will see a Gatekeeper warning unless the app is **signed with a Developer ID certificate and notarized**. That requires the paid Apple Developer Program.

1. In the developer portal, create a **Developer ID Application** certificate and install it in your login keychain.
2. Store notarization credentials:
   ```sh
   xcrun notarytool store-credentials rasternest --apple-id you@example.com --team-id TEAMID
   ```
   (Use an app-specific password from appleid.apple.com.)
3. Build, package and notarize locally:
   ```sh
   UNIVERSAL=1 SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh
   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/make-dmg.sh
   NOTARY_PROFILE=rasternest ./scripts/notarize.sh build/RasterNest-$(cat VERSION).dmg
   ```

An *Apple Development* certificate (what local builds use) is fine for your own Mac, but notarization rejects it.

## 2. Automated releases (GitHub Actions)

Add these repository secrets, then push a tag such as `v0.2.0`:

| Secret | Value |
|---|---|
| `MACOS_CERT_P12_BASE64` | `base64 -i DeveloperID.p12` |
| `MACOS_CERT_PASSWORD` | the .p12 export password |
| `MACOS_SIGN_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | notarization login |
| `HOMEBREW_TAP_TOKEN` | fine-grained PAT with write access to `AMineer/homebrew-tap` |

`.github/workflows/release.yml` then:
- builds a universal, signed and notarized `RasterNest-x.y.z.dmg`
- builds `rnest` tarballs for macOS (universal) and Linux (x86_64 + aarch64, static Swift stdlib)
- creates the GitHub Release with `SHA256SUMS.txt`
- renders `Casks/rasternest.rb` and `Formula/rnest.rb` and pushes them to your tap

Without the secrets, the release still builds, but ad-hoc signed and not notarized.

## 3. Homebrew tap

Create an empty public repo named **`homebrew-tap`** under the same owner. Users then run:

```sh
brew install --cask amineer/tap/rasternest   # app + rnest (macOS)
brew install amineer/tap/rnest               # CLI only (macOS or Linux)
```

Templates live in `packaging/homebrew/`, and `scripts/render-homebrew.sh` fills in versions and checksums. Once the project is well known, you can submit the cask to `homebrew/cask`.

## 4. Hosting on your website

Link to the GitHub release asset (it's stable and versioned), or upload the DMG to your site. Publish the SHA-256 from `SHA256SUMS.txt` next to it. For in-app updates, [Sparkle](https://sparkle-project.org) is the standard choice (see the roadmap).

## Bundle identifier

The app uses `app.rasternest.RasterNest` (in `Resources/Info.plist` and `RasterNestInfo.bundleIdentifier`). If you'd rather use a domain you own, change both places before the first public release.

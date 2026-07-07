# Release

ScreenOff currently ships unsigned because the project does not yet have an Apple Developer account.

## Current Release Path

Push a version tag:

```sh
git tag v0.1.1
git push origin v0.1.1
```

Or run the `Release` workflow manually from GitHub Actions with a version such as `0.1.1`.

The workflow builds `ScreenOff.app`, packages `ScreenOff-<version>.zip`, creates a GitHub Release, and prints the SHA-256 in the release notes.

## Homebrew Tap Automation

To let the workflow update `nickxudotme/homebrew-tap` automatically, add this secret to the `screenoff` GitHub repository:

```text
TAP_DEPLOY_KEY
```

This is the private half of a write-enabled deploy key on `nickxudotme/homebrew-tap`.

Without that secret, the release still succeeds, but the cask must be updated manually:

```ruby
version "0.1.1"
sha256 "<zip sha256>"
```

## Unsigned App Behavior

Homebrew can install the app and CLI, but macOS Gatekeeper may block the GUI on first launch because the app is unsigned and not notarized.

If macOS reports that the app is damaged, remove the quarantine attribute after installation:

```sh
xattr -dr com.apple.quarantine /Applications/ScreenOff.app
```

When an Apple Developer account is available, add these steps before packaging:

1. Sign `ScreenOff.app`, `ScreenOffApp`, `screenoff`, and `m1ddc` with Developer ID.
2. Enable hardened runtime.
3. Submit the zip or app for notarization with `notarytool`.
4. Staple the notarization ticket with `stapler`.
5. Package the notarized app and update the cask SHA-256.

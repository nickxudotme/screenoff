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

The Homebrew cask installs the app and CLI, then uses `postflight_steps` to:

1. Explain that ScreenOff is not notarized and print the exact command with the actual application directory.
2. Run `sudo /usr/bin/xattr -dr com.apple.quarantine "<appdir>/ScreenOff.app"` automatically.
3. Let sudo prompt for the Mac administrator password when authentication is needed. Homebrew handles the prompt; the cask does not read or store the password.

These steps run during installation, reinstallation, and upgrades. They respect `brew --appdir`; only ScreenOff's quarantine attribute is removed. A terminal capable of accepting sudo authentication is required when there is no cached authentication. Removing quarantine does not sign or notarize the app.

For manually downloaded ZIPs, if macOS blocks the app, run (adjust the installation path if needed):

```sh
xattr -dr com.apple.quarantine /Applications/ScreenOff.app
```

When an Apple Developer account is available, add these steps before packaging:

1. Sign `ScreenOff.app`, `ScreenOffApp`, `screenoff`, and `m1ddc` with Developer ID.
2. Enable hardened runtime.
3. Submit the zip or app for notarization with `notarytool`.
4. Staple the notarization ticket with `stapler`.
5. Package the notarized app and update the cask SHA-256.

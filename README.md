# ScreenOff

ScreenOff is a small macOS utility for turning displays off and restoring them later. It ships as both:

- `screenoff`, a command line tool
- `ScreenOff.app`, a simple SwiftUI app

ScreenOff has one user-facing action: connect or disconnect an external display. By default it uses macOS display-topology control, so a disconnected display disappears from System Settings and the usable desktop layout. It asks WindowServer for the full display inventory when reconnecting, which includes a display ScreenOff disconnected even though it has left the public online-display list. A small local history is only a fallback for a monitor that WindowServer no longer enumerates. DDC/CI and m1ddc are compatibility fallbacks when topology control is unavailable.

## Requirements

- macOS 13 or newer
- Swift 6 toolchain
- Xcode command line tools

## Install

```sh
brew install --cask nickxudotme/tap/screenoff
```

ScreenOff is currently unsigned and not notarized. Homebrew can install it, but macOS may require manual approval in System Settings > Privacy & Security before the GUI opens for the first time.

If macOS says the app is damaged, remove the quarantine attribute after installing:

```sh
xattr -dr com.apple.quarantine /Applications/ScreenOff.app
```

## Build

Build the command line tool and GUI executable:

```sh
swift build -c release
```

The CLI binary is:

```sh
.build/release/screenoff
```

Build a local app bundle:

```sh
./scripts/build-release.sh
```

The app bundle is written to:

```sh
dist/ScreenOff.app
```

## CLI Usage

```sh
screenoff list
screenoff list --json
screenoff disconnect <display>
screenoff reconnect <display>
screenoff disconnect all
screenoff reconnect all
screenoff toggle external
```

`<display>` can be:

- a display ID, for example `1234567890`
- a 1-based list index, for example `#2`
- a case-insensitive name fragment, for example `studio`

By default, `disconnect` refuses to disconnect the main display. Add `--force-main` only if you really mean it:

```sh
screenoff disconnect "#1" --force-main
```

To restore every disconnected external display:

```sh
screenoff reconnect all
```

`toggle external` disconnects every external display when they are all connected. If one or more are already disconnected, it reconnects them all.

If a monitor is physically unplugged and no longer appears in the system inventory, restore it by numeric display ID after reconnecting its cable:

```sh
screenoff reconnect 1234567890 --backend coregraphics
```

`list` collapses CoreGraphics mirror-set members into one controllable display. The JSON output includes the system `uuid`, and an EDID-derived `identity` when the monitor exposes a complete vendor/model/serial tuple. Display IDs are routing handles that can change after reconnecting; the UUID and identity are used only to recognize a display, while WindowServer's current ID performs the reconnect.

## GUI Usage

Build the bundle, then open it:

```sh
./scripts/build-release.sh
open dist/ScreenOff.app
```

The app lists connected displays, protects the main display from accidental disconnects, and keeps disconnected screens in a Disconnected section for one-click reconnection.

## Backends

- `coregraphics`: uses private CoreGraphics symbols to enable or disable a display in the macOS desktop topology.
- `ddc`: a compatibility fallback that sends DDC/CI power commands directly through IOKit.
- `m1ddc`: a compatibility fallback that uses the bundled `m1ddc` helper for DDC/CI commands.
- `auto`: tries topology control first, then DDC/CI fallbacks.

The CoreGraphics backend depends on private macOS symbols, so it may break on future macOS releases.

## Vendored Code

The optional `m1ddc` helper is vendored from <https://github.com/waydabber/m1ddc> and is MIT licensed. Its license is included at `Vendor/m1ddc/LICENSE` and copied into the app bundle by the release script.

## Releases

See [docs/release.md](docs/release.md) for the current unsigned release workflow and the future signing/notarization path.

# ScreenOff

ScreenOff is a small macOS utility for turning displays off and restoring them later. It ships as both:

- `screenoff`, a command line tool
- `ScreenOff.app`, a simple SwiftUI app

The default backend uses macOS display topology control. When a display is turned off this way, it disappears from the usable desktop layout, windows cannot be dragged there, and System Settings no longer treats it as active. ScreenOff can also fall back to DDC/CI power commands for external monitors.

## Requirements

- macOS 13 or newer
- Swift 6 toolchain
- Xcode command line tools

## Install

```sh
brew install --cask nickxudotme/tap/screenoff
```

ScreenOff is currently unsigned and not notarized. Homebrew can install it, but macOS may require manual approval in System Settings > Privacy & Security before the GUI opens for the first time.

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
screenoff off <display>
screenoff on <display>
screenoff on all
screenoff toggle <display>
screenoff off <display> --backend coregraphics
screenoff off <display> --backend m1ddc
```

`<display>` can be:

- a display ID, for example `1234567890`
- a 1-based list index, for example `#2`
- a case-insensitive name fragment, for example `studio`

By default, `off` refuses to disable the main display. Add `--force-main` only if you really mean it:

```sh
screenoff off "#1" --force-main
```

If you turn off the wrong display, restore all currently listed displays:

```sh
screenoff on all
```

If a display no longer appears in `screenoff list` after topology disable, restore it by numeric display ID:

```sh
screenoff on 1234567890 --backend coregraphics
```

## GUI Usage

Build the bundle, then open it:

```sh
./scripts/build-release.sh
open dist/ScreenOff.app
```

The app lists active displays, protects the main display from accidental shutoff, remembers display IDs turned off through the app, and lets you restore a display manually by ID.

## Backends

- `coregraphics`: uses private CoreGraphics symbols to enable or disable a display in the macOS desktop topology.
- `ddc`: sends DDC/CI power mode commands directly through IOKit.
- `m1ddc`: uses the bundled `m1ddc` helper for DDC/CI commands.
- `auto`: tries topology control first, then DDC/CI fallbacks.

The CoreGraphics backend depends on private macOS symbols, so it may break on future macOS releases.

## Vendored Code

The optional `m1ddc` helper is vendored from <https://github.com/waydabber/m1ddc> and is MIT licensed. Its license is included at `Vendor/m1ddc/LICENSE` and copied into the app bundle by the release script.

## Releases

See [docs/release.md](docs/release.md) for the current unsigned release workflow and the future signing/notarization path.

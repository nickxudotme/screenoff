#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build -c release

if [ -d Vendor/m1ddc ]; then
  make -C Vendor/m1ddc
fi

APP_DIR="$ROOT/dist/ScreenOff.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$ROOT/dist"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$ROOT/.build/release/ScreenOffApp" "$MACOS_DIR/ScreenOffApp"
cp "$ROOT/.build/release/screenoff" "$RESOURCES_DIR/screenoff"
cp "$ROOT/Resources/ScreenOff-Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT/Resources/ScreenOff.icns" "$RESOURCES_DIR/ScreenOff.icns"

if [ -x "$ROOT/Vendor/m1ddc/m1ddc" ]; then
  cp "$ROOT/Vendor/m1ddc/m1ddc" "$RESOURCES_DIR/m1ddc"
  cp "$ROOT/Vendor/m1ddc/LICENSE" "$RESOURCES_DIR/M1DDC-LICENSE"
fi

chmod +x "$MACOS_DIR/ScreenOffApp" "$RESOURCES_DIR/screenoff"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$RESOURCES_DIR/screenoff"
  if [ -x "$RESOURCES_DIR/m1ddc" ]; then
    codesign --force --sign - "$RESOURCES_DIR/m1ddc"
  fi
  codesign --force --deep --sign - "$APP_DIR"
fi

echo "Built $APP_DIR"

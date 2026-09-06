#!/usr/bin/env bash
set -euo pipefail

EXTENSION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$EXTENSION_ROOT/.." && pwd)"

swift build -c release --product screenoff --package-path "$PROJECT_ROOT"
make -C "$PROJECT_ROOT/Vendor/m1ddc"

mkdir -p "$EXTENSION_ROOT/assets"
cp "$PROJECT_ROOT/.build/release/screenoff" "$EXTENSION_ROOT/assets/screenoff"
cp "$PROJECT_ROOT/Vendor/m1ddc/m1ddc" "$EXTENSION_ROOT/assets/m1ddc"
chmod +x "$EXTENSION_ROOT/assets/screenoff" "$EXTENSION_ROOT/assets/m1ddc"

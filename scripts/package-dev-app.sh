#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/build/TokenMeter.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"
swift build
SWIFT_BIN_DIR="$(swift build --show-bin-path)"
npm install --prefix "$ROOT_DIR/Electron"
npm run build --prefix "$ROOT_DIR/Electron"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$SWIFT_BIN_DIR/TokenMeterApp" "$MACOS_DIR/TokenMeterApp"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp -R "$ROOT_DIR/Electron" "$RESOURCES_DIR/Electron"
npm run rebuild:native --prefix "$RESOURCES_DIR/Electron" -- -f -w better-sqlite3 --build-from-source
node "$RESOURCES_DIR/Electron/node_modules/electron/cli.js" --version >/dev/null
cp -R "$SWIFT_BIN_DIR/TokenMeter_TokenMeterApp.bundle" "$RESOURCES_DIR/TokenMeter_TokenMeterApp.bundle"
cp -R "$SWIFT_BIN_DIR/TokenMeter_TokenMeterCore.bundle" "$RESOURCES_DIR/TokenMeter_TokenMeterCore.bundle"
codesign --remove-signature "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign - --identifier com.luwei.tokenmeter "$APP_DIR" >/dev/null
codesign --verify --deep --strict "$APP_DIR"

echo "$APP_DIR"

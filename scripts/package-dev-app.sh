#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/build/TokenMeter.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

cd "$ROOT_DIR"
swift build

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$ROOT_DIR/.build/debug/TokenMeterApp" "$MACOS_DIR/TokenMeterApp"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
codesign --remove-signature "$APP_DIR" 2>/dev/null || true
codesign --remove-signature "$MACOS_DIR/TokenMeterApp" 2>/dev/null || true
codesign --force --sign - --identifier com.luwei.tokenmeter "$MACOS_DIR/TokenMeterApp" >/dev/null
codesign --force --sign - --identifier com.luwei.tokenmeter "$APP_DIR" >/dev/null
cp -R "$ROOT_DIR/.build/debug/TokenMeter_TokenMeterApp.bundle" "$APP_DIR/TokenMeter_TokenMeterApp.bundle"

echo "$APP_DIR"

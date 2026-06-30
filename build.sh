#!/bin/bash
# Build AriseCreditChecker.app — native macOS menu bar app, no dependencies.
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="Arise Credit"
EXEC_NAME="AriseCreditChecker"
BUILD_DIR=".build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "▸ Compiling Swift…"
xcrun swiftc \
    -O \
    -target arm64-apple-macos12 \
    -sdk "$(xcrun --show-sdk-path)" \
    Sources/AriseCreditChecker/main.swift \
    -o "$BUILD_DIR/$EXEC_NAME"

echo "▸ Assembling .app bundle…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BUILD_DIR/$EXEC_NAME" "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

echo "▸ Done."
echo "  $APP_BUNDLE"
echo
echo "Run:    open \"$APP_BUNDLE\""
echo "Launch: open \"$APP_BUNDLE\" --hide-other-apps"

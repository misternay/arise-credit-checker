#!/bin/bash
# build-release.sh — produce distributable artifacts for Arise Credit Checker.
#
# Builds a universal (arm64 + x86_64) .app, then packs a .zip and a .dmg.
# Output lands in dist/. Run on macOS; requires Xcode command-line tools.
#
# Usage:  ./build-release.sh [version]
#   version defaults to the value in Info.plist (CFBundleShortVersionString)
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="Arise Credit"
EXEC_NAME="AriseCreditChecker"
DIST="dist"
SDK="$(xcrun --show-sdk-path)"
VERSION="${1:-}"

if [ -z "$VERSION" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
fi
echo "▸ Building $APP_NAME v$VERSION (universal)"

# Fresh build dir.
rm -rf "$DIST"
mkdir -p "$DIST"

echo "▸ Compiling universal Swift binary (arm64 + x86_64)…"
# Swift can't emit a universal binary in one shot, so compile each slice
# and fuse them with lipo.
xcrun swiftc -O -target arm64-apple-macos12   -sdk "$SDK" Sources/AriseCreditChecker/main.swift -o "$DIST/$EXEC_NAME.arm64"
xcrun swiftc -O -target x86_64-apple-macos12  -sdk "$SDK" Sources/AriseCreditChecker/main.swift -o "$DIST/$EXEC_NAME.x86_64"
lipo -create -output "$DIST/$EXEC_NAME" "$DIST/$EXEC_NAME.arm64" "$DIST/$EXEC_NAME.x86_64"
rm -f "$DIST/$EXEC_NAME.arm64" "$DIST/$EXEC_NAME.x86_64"
echo "  $(lipo -archs "$DIST/$EXEC_NAME") binary built"

echo "▸ Assembling .app bundle…"
APP_BUNDLE="$DIST/$APP_NAME.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$DIST/$EXEC_NAME" "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -f "$DIST/$EXEC_NAME"

# Stamp the version into the bundle.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true

echo "▸ Ad-hoc signing the bundle…"
# Sign with a stable identifier taken from Info.plist (dev.arisetech.arisecredit).
# This replaces the bare "linker-signed" signature Swift leaves behind with a
# proper bundle signature. Ad-hoc (--sign -) is the best you can do without a
# paid Apple Developer ID; it does NOT satisfy Gatekeeper on its own, but it
# makes the bundle well-formed so that "xattr -dr com.apple.quarantine" fully
# clears the "damaged / move to Trash" warning. See README → Install.
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_BUNDLE/Contents/Info.plist")
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"
codesign --verify --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/  /'

echo "▸ Creating ZIP…"
ditto -c -k --keepParent "$APP_BUNDLE" "$DIST/$APP_NAME-$VERSION.zip"

echo "▸ Creating DMG…"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"
# hdiutil create -srcfolder copies the .app into a read-only DMG.
hdiutil create -volname "$APP_NAME" -srcfolder "$APP_BUNDLE" -ov -fs HFS+ "$DMG" >/dev/null

echo "▸ Computing SHA256…"
(
    cd "$DIST"
    shasum -a 256 "$APP_NAME-$VERSION.zip" "$APP_NAME-$VERSION.dmg"
) | tee "$DIST/sha256sums.txt"

echo
echo "✓ Done. Artifacts in $DIST/:"
ls -lh "$DIST"
echo
echo "Next:"
echo "  gh release create v$VERSION $DIST/*.zip $DIST/*.dmg $DIST/sha256sums.txt --title v$VERSION --notes '...' "

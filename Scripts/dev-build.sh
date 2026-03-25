#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="WindowLock.app"
APP_DIR="$SCRIPT_DIR/.build/$APP_NAME"
BINARY_SRC=".build/arm64-apple-macosx/debug/WindowLock"

cd "$SCRIPT_DIR"

# --- Build ---
echo "Building (debug)..."
swift build 2>&1

# --- Create .app bundle ---
echo "Assembling $APP_NAME..."
chmod -R u+w "$APP_DIR" 2>/dev/null || true
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY_SRC" "$APP_DIR/Contents/MacOS/WindowLock"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# Ad-hoc sign the bundle (bundle ID is in Info.plist)
codesign --force --sign - "$APP_DIR" 2>&1

echo ""
echo "Done! Run with:"
echo "  open $APP_DIR"
echo ""
echo "Or directly:"
echo "  $APP_DIR/Contents/MacOS/WindowLock"
echo ""
echo "First time? Grant Accessibility permission to WindowLock.app:"
echo "  System Settings > Privacy & Security > Accessibility"
echo "  The app should appear as 'WindowLock' — just enable the toggle."
echo ""
echo "Because it's a proper .app bundle with a bundle ID (com.way2do.windowlock),"
echo "the permission survives rebuilds."

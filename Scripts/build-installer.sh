#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="WindowLock.app"
BUNDLE_ID="com.way2do.windowlock"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
PKG_NAME="WindowLock-${VERSION}.pkg"

BUILD_DIR=".build"
APP_DIR="$BUILD_DIR/$APP_NAME"
INSTALLER_ROOT="$BUILD_DIR/installer-root"
COMPONENT_PKG="$BUILD_DIR/WindowLock-component.pkg"
FINAL_PKG="$BUILD_DIR/$PKG_NAME"

echo "=== WindowLock Installer Builder ==="
echo "Version: $VERSION"
echo ""

# --- Phase 1: Build release binary ---
echo "[1/5] Building release binary..."
swift build -c release 2>&1

# Detect binary path (arm64 or universal)
if [ -f "$BUILD_DIR/release/WindowLock" ]; then
  BINARY="$BUILD_DIR/release/WindowLock"
elif [ -f "$BUILD_DIR/arm64-apple-macosx/release/WindowLock" ]; then
  BINARY="$BUILD_DIR/arm64-apple-macosx/release/WindowLock"
else
  echo "ERROR: Cannot find release binary"
  exit 1
fi
echo "  Binary: $BINARY"

# --- Phase 2: Assemble .app bundle ---
echo "[2/5] Assembling $APP_NAME..."
chmod -R u+w "$APP_DIR" 2>/dev/null || true
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/WindowLock"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "Scripts/uninstall.sh" "$APP_DIR/Contents/Resources/uninstall.sh"
chmod +x "$APP_DIR/Contents/Resources/uninstall.sh"

# Ad-hoc sign the bundle
codesign --force --sign - "$APP_DIR"
echo "  Signed: $APP_DIR"

# --- Phase 3: Prepare installer payload ---
echo "[3/5] Preparing installer payload..."
INSTALLER_ROOT="$BUILD_DIR/installer-root"
rm -rf "$INSTALLER_ROOT"
mkdir -p "$INSTALLER_ROOT/Applications"
cp -R "$APP_DIR" "$INSTALLER_ROOT/Applications/"

# Component plist to prevent relocation (forces install to /Applications)
COMPONENT_PLIST="$BUILD_DIR/component.plist"
cat > "$COMPONENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
  <dict>
    <key>BundleHasStrictIdentifier</key>
    <true/>
    <key>BundleIsRelocatable</key>
    <false/>
    <key>BundleIsVersionChecked</key>
    <false/>
    <key>BundleOverwriteAction</key>
    <string>upgrade</string>
    <key>RootRelativeBundlePath</key>
    <string>Applications/WindowLock.app</string>
  </dict>
</array>
</plist>
EOF

# --- Phase 4: Build component package ---
echo "[4/5] Building component package..."
pkgbuild \
  --root "$INSTALLER_ROOT" \
  --identifier "$BUNDLE_ID" \
  --version "$VERSION" \
  --install-location / \
  --component-plist "$COMPONENT_PLIST" \
  --scripts Installer/scripts \
  "$COMPONENT_PKG" 2>&1

# --- Phase 5: Build product archive ---
echo "[5/5] Building installer package..."
productbuild \
  --distribution Installer/distribution.xml \
  --resources Installer/ \
  --package-path "$BUILD_DIR" \
  "$FINAL_PKG" 2>&1

# --- Cleanup ---
rm -rf "$INSTALLER_ROOT" "$COMPONENT_PKG" "$COMPONENT_PLIST"

# --- Done ---
SIZE=$(du -h "$FINAL_PKG" | awk '{print $1}')
echo ""
echo "=== Installer built successfully ==="
echo "  Package: $FINAL_PKG"
echo "  Size:    $SIZE"
echo ""
echo "To install:"
echo "  open $FINAL_PKG"
echo ""
echo "If macOS blocks the installer (Gatekeeper):"
echo "  xattr -cr $FINAL_PKG"

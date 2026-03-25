#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="WindowLock.app"
INSTALL_DIR="/Applications"
INSTALL_PATH="$INSTALL_DIR/$APP_NAME"
PLIST_NAME="com.way2do.windowlock.plist"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

echo "Building WindowLock..."
cd "$SCRIPT_DIR"
swift build -c release

echo "Assembling $APP_NAME..."
BUILD_APP="$SCRIPT_DIR/.build/$APP_NAME"
rm -rf "$BUILD_APP"
mkdir -p "$BUILD_APP/Contents/MacOS"
mkdir -p "$BUILD_APP/Contents/Resources"

cp ".build/release/WindowLock" "$BUILD_APP/Contents/MacOS/WindowLock"
cp "Resources/Info.plist" "$BUILD_APP/Contents/Info.plist"

# Ad-hoc sign the bundle
codesign --force --sign - "$BUILD_APP"

echo "Installing to $INSTALL_PATH..."
# Remove old bare binary if it exists
if [ -f /usr/local/bin/windowlock ]; then
  echo "Removing old binary at /usr/local/bin/windowlock..."
  sudo rm -f /usr/local/bin/windowlock
fi

# Copy app bundle to /Applications
rm -rf "$INSTALL_PATH"
cp -R "$BUILD_APP" "$INSTALL_PATH"

echo "Installing LaunchAgent..."
mkdir -p "$LAUNCH_AGENTS_DIR"

# Update plist to point to the app bundle binary
cat > "$LAUNCH_AGENTS_DIR/$PLIST_NAME" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.way2do.windowlock</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_PATH/Contents/MacOS/WindowLock</string>
    <string>--daemon</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>/tmp/windowlock-stdout.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/windowlock-stderr.log</string>
</dict>
</plist>
EOF

# Unload if already loaded
launchctl bootout "gui/$(id -u)/$PLIST_NAME" 2>/dev/null || true

echo "Loading LaunchAgent..."
launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENTS_DIR/$PLIST_NAME"

echo ""
echo "WindowLock installed to $INSTALL_PATH and running!"
echo ""
echo "IMPORTANT: Grant Accessibility access:"
echo "  System Settings > Privacy & Security > Accessibility"
echo "  Add WindowLock.app from /Applications (or it may appear automatically)"
echo ""
echo "Logs: /tmp/windowlock-stderr.log"

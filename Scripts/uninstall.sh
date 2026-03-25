#!/bin/bash
set -e

APP_NAME="WindowLock.app"
APP_PATH="/Applications/$APP_NAME"
OLD_BINARY="/usr/local/bin/windowlock"
PLIST_NAME="com.way2do.windowlock.plist"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
DATA_DIR="$HOME/Library/Application Support/WindowLock"

echo "Stopping WindowLock..."
launchctl bootout "gui/$(id -u)/$PLIST_NAME" 2>/dev/null || true

echo "Removing LaunchAgent..."
rm -f "$LAUNCH_AGENTS_DIR/$PLIST_NAME"

echo "Removing app..."
if [ -d "$APP_PATH" ]; then
  rm -rf "$APP_PATH"
  echo "  Removed $APP_PATH"
fi

# Clean up old bare binary if present
if [ -f "$OLD_BINARY" ]; then
  echo "Removing old binary..."
  sudo rm -f "$OLD_BINARY"
fi

echo "Removing logs..."
rm -f /tmp/windowlock-stdout.log /tmp/windowlock-stderr.log

if [ "$1" = "--purge" ]; then
  echo "Removing all saved data (layouts and state)..."
  rm -rf "$DATA_DIR"
  echo "WindowLock fully purged."
else
  echo ""
  echo "WindowLock uninstalled."
  echo "Saved data preserved in: $DATA_DIR"
  echo "To also remove saved layouts and state: $0 --purge"
fi

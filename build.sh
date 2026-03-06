#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/ClaudeRootHelper.app"

echo "Building ClaudeRootHelper..."

# Clean
rm -rf "$APP"

# Compile
swiftc "$DIR/ClaudeRootHelper.swift" \
    -o "$DIR/ClaudeRootHelper_bin" \
    -framework Cocoa \
    -O

# Create .app bundle
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mv "$DIR/ClaudeRootHelper_bin" "$APP/Contents/MacOS/ClaudeRootHelper"
cp "$DIR/Info.plist" "$APP/Contents/"
cp "$DIR/server.py" "$APP/Contents/Resources/"
cp "$DIR/claude-root-cmd" "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/claude-root-cmd"

# Ad-hoc sign
codesign --force --deep --sign - "$APP"

echo ""
echo "Built: $APP"
echo ""
echo "To use:"
echo "  1. Double-click ClaudeRootHelper.app (it will ask for your password once)"
echo "  2. The app window shows it's running"
echo "  3. Claude can now use: claude-root-cmd <command>"
echo "  4. Quit the app when done — the helper stops automatically"

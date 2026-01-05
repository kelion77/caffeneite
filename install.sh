#!/bin/bash
# AntiSleep.spoon Installer

set -e

SPOON_DIR="$HOME/.hammerspoon/Spoons"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing AntiSleep.spoon..."

# Create Spoons directory if it doesn't exist
mkdir -p "$SPOON_DIR"

# Copy the Spoon
cp -r "$SCRIPT_DIR/AntiSleep.spoon" "$SPOON_DIR/"

echo "✅ Installed to $SPOON_DIR/AntiSleep.spoon"
echo ""
echo "Add this to your ~/.hammerspoon/init.lua:"
echo ""
echo '  hs.loadSpoon("AntiSleep")'
echo '  spoon.AntiSleep:bindHotkeys({toggle = {{"shift", "cmd"}, "k"}})'
echo ""
echo "Then reload Hammerspoon (Shift+Cmd+R or click icon → Reload Config)"

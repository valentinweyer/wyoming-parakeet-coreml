#!/bin/bash
# Removes the WyomingParakeet LaunchAgent and installed files.
set -euo pipefail

INSTALL_ROOT="/usr/local/wyoming-parakeet-de"
PLIST_LABEL="local.wyoming-parakeet-de"
PLIST_DEST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

echo "-- Stopping and unloading LaunchAgent --"
launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || echo "   (was not running)"
rm -f "$PLIST_DEST"

read -p "Remove $INSTALL_ROOT (binary + model bundle + logs)? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    sudo rm -rf "$INSTALL_ROOT"
    echo "Removed $INSTALL_ROOT"
else
    echo "Left $INSTALL_ROOT in place."
fi

echo "Done."

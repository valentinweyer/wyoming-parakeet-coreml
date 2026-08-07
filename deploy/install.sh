#!/bin/bash
# Installs WyomingParakeet as a per-user LaunchAgent.
#
# Run this from this deploy/ directory, on the Mac that will run the
# service (build the binary first — see the main README — or use a
# pre-built release binary if one's provided).
set -euo pipefail

INSTALL_ROOT="/usr/local/wyoming-parakeet-de"
PLIST_LABEL="local.wyoming-parakeet-de"
PLIST_DEST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== WyomingParakeet install =="
echo "Install root: $INSTALL_ROOT"
echo

if [ "$(uname -m)" != "arm64" ]; then
    echo "ERROR: this binary is arm64-only (built for Apple Silicon). Refusing to install on $(uname -m)." >&2
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/bin/WyomingParakeet" ]; then
    echo "ERROR: $SCRIPT_DIR/bin/WyomingParakeet not found." >&2
    echo "Build it first: swift build -c release (from the repo root), then copy" >&2
    echo "  .build/release/WyomingParakeet into $SCRIPT_DIR/bin/" >&2
    exit 1
fi

if [ ! -d "$SCRIPT_DIR/models/parakeet-tdt-0.6b-v3" ]; then
    echo "ERROR: $SCRIPT_DIR/models/parakeet-tdt-0.6b-v3 not found." >&2
    echo "Put your converted CoreML model bundle there first (see the main README" >&2
    echo "for where to get one, or how to convert your own)." >&2
    exit 1
fi

echo "-- Checking for an existing installation --"
if launchctl print "gui/$(id -u)/${PLIST_LABEL}" >/dev/null 2>&1; then
    echo "Existing instance is running — stopping it first."
    launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || true
fi

echo "-- Laying out $INSTALL_ROOT --"
sudo mkdir -p "$INSTALL_ROOT/bin" "$INSTALL_ROOT/models" "$INSTALL_ROOT/logs"
sudo chown -R "$(whoami)" "$INSTALL_ROOT"

echo "-- Copying binary --"
cp "$SCRIPT_DIR/bin/WyomingParakeet" "$INSTALL_ROOT/bin/WyomingParakeet"
chmod +x "$INSTALL_ROOT/bin/WyomingParakeet"

# A binary copied between Macs (even over rsync/AirDrop, not just a browser
# download) can carry a com.apple.quarantine xattr that blocks execution or
# triggers an unexpected Gatekeeper prompt. Strip it, then ad-hoc codesign so
# the firewall's incoming-connection decision is tied to a stable identity
# and doesn't re-prompt on every rebuild.
echo "-- Clearing quarantine + ad-hoc codesigning --"
xattr -d com.apple.quarantine "$INSTALL_ROOT/bin/WyomingParakeet" 2>/dev/null || true
codesign -s - --force "$INSTALL_ROOT/bin/WyomingParakeet"

echo "-- Copying model bundle --"
if [ -d "$INSTALL_ROOT/models/parakeet-tdt-0.6b-v3" ]; then
    echo "   (removing previous model bundle first)"
    rm -rf "$INSTALL_ROOT/models/parakeet-tdt-0.6b-v3"
fi
cp -R "$SCRIPT_DIR/models/parakeet-tdt-0.6b-v3" "$INSTALL_ROOT/models/"

echo "-- Verifying model bundle --"
for f in Preprocessor.mlmodelc Encoder.mlmodelc Decoder.mlmodelc JointDecisionv3.mlmodelc parakeet_vocab.json; do
    if [ ! -e "$INSTALL_ROOT/models/parakeet-tdt-0.6b-v3/$f" ]; then
        echo "ERROR: missing $f after copy — install did not complete correctly." >&2
        exit 1
    fi
done
echo "   OK — all required files present."

echo "-- Installing LaunchAgent --"
mkdir -p "$HOME/Library/LaunchAgents"
cp "$SCRIPT_DIR/${PLIST_LABEL}.plist" "$PLIST_DEST"
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"
launchctl enable "gui/$(id -u)/${PLIST_LABEL}"

echo
echo "== Installed and started =="
echo "Logs: $INSTALL_ROOT/logs/stdout.log, $INSTALL_ROOT/logs/stderr.log"
echo "Check status: launchctl print gui/\$(id -u)/${PLIST_LABEL}"
echo "Health probe: $SCRIPT_DIR/health_check.sh"
echo
echo "If you're using a model other than the default German primeline"
echo "fine-tune, edit the --model-name/--language/--attribution-* flags in"
echo "${PLIST_LABEL}.plist before installing (or after, then"
echo "  launchctl bootout gui/\$(id -u)/${PLIST_LABEL}"
echo "  cp ${PLIST_LABEL}.plist \"$PLIST_DEST\""
echo "  launchctl bootstrap gui/\$(id -u) \"$PLIST_DEST\""
echo "to apply the change)."
echo
echo "REMINDER — for this to survive a reboot and keep answering:"
echo "  1. This Mac must be set to auto-login (System Settings > Users & Groups > Login Options)."
echo "  2. Sleep should be disabled (System Settings > Energy — prevent automatic sleeping)."
echo "  3. The first time something connects, macOS's firewall may prompt to allow incoming"
echo "     connections for WyomingParakeet — accept it, or it'll silently refuse connections."

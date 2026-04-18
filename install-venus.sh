#!/usr/bin/env bash

# Venus OS install/reinstall script for SH-RPi daemon.
#
# Run this after a fresh clone of the repo on the Pi, or after a Venus OS
# update wipes /service/ entries. Safe to run repeatedly.
#
# Must be run as root from the repository root directory:
#   sudo ./install-venus.sh
#
# What this script does:
#   1. Installs required Python packages via opkg/pip
#   2. Copies src/shrpi/*.py to /data/sh-rpi-venus/
#   3. Creates the daemontools service in /opt/victronenergy/service/ and /service/
#   4. Installs the GUI page (GUI v1 only)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$REPO_ROOT/src/shrpi"
DAEMON_DEST="/data/sh-rpi-venus"
SERVICE_NAME="sh-rpi-venus"
OPT_SERVICE_DIR="/opt/victronenergy/service/$SERVICE_NAME"
LIVE_SERVICE_DIR="/service/$SERVICE_NAME"
GUI_SRC="$REPO_ROOT/GUI/PageSailorHat.qml"
GUI_QML_DIR="/opt/victronenergy/gui/qml"
SETTINGS_PAGE="$GUI_QML_DIR/PageSettingsGeneral.qml"

# Bail out if not running as root
if [ "$(id -u)" != "0" ]; then
    echo "ERROR: This script must be run as root" 1>&2
    exit 1
fi

# Bail out if not running on Venus OS
if ! command -v svstat &>/dev/null || ! command -v opkg &>/dev/null; then
    echo "ERROR: This script is intended for Venus OS only (svstat/opkg not found)" 1>&2
    exit 1
fi

echo "==> SH-RPi Venus OS installer"
echo "    Repo root: $REPO_ROOT"
echo ""

# --- 1. Python dependencies ---
echo "--> Installing Python dependencies"
opkg update
opkg install python3-pip

python3 -m pip install --quiet --prefer-binary pyyaml smbus2 dateparser typer rich

# aiohttp is imported but the HTTP server is disabled; install it anyway to
# avoid import errors at startup
python3 -m pip install --quiet --prefer-binary aiohttp

echo "    Python dependencies installed."

# --- 2. Daemon source files ---
echo "--> Copying daemon source files to $DAEMON_DEST"
mkdir -p "$DAEMON_DEST"
cp "$SRC_DIR"/*.py "$DAEMON_DEST/"
chmod -R 755 "$DAEMON_DEST"
# The entry point is daemon.py — make sure it is executable
chmod +x "$DAEMON_DEST/daemon.py"
echo "    Source files copied."

# --- 3. Daemontools service ---
echo "--> Installing daemontools service"

# Install to the persistent location first so it survives reboots
mkdir -p "$OPT_SERVICE_DIR/log"

cat > "$OPT_SERVICE_DIR/run" << 'EOF'
#!/bin/sh
exec 2>&1
exec /data/sh-rpi-venus/daemon.py
EOF
chmod +x "$OPT_SERVICE_DIR/run"

cat > "$OPT_SERVICE_DIR/log/run" << 'EOF'
#!/bin/sh
exec 2>&1
exec multilog t s99999 n8 /var/log/sh-rpi-venus
EOF
chmod +x "$OPT_SERVICE_DIR/log/run"

# Also install to the live tmpfs /service so the daemon starts immediately
# without requiring a reboot
mkdir -p "$LIVE_SERVICE_DIR/log"
cp "$OPT_SERVICE_DIR/run"     "$LIVE_SERVICE_DIR/run"
cp "$OPT_SERVICE_DIR/log/run" "$LIVE_SERVICE_DIR/log/run"
chmod +x "$LIVE_SERVICE_DIR/run" "$LIVE_SERVICE_DIR/log/run"

echo "    Service installed in $OPT_SERVICE_DIR and $LIVE_SERVICE_DIR."

# --- 4. GUI page (GUI v1 only) ---
if [ -d "$GUI_QML_DIR" ]; then
    echo "--> Installing GUI page"
    cp "$GUI_SRC" "$GUI_QML_DIR/PageSailorHat.qml"

    # Add SailorHat menu entry to PageSettingsGeneral.qml if not already present
    if ! grep -q "PageSailorHat" "$SETTINGS_PAGE" 2>/dev/null; then
        echo "    Patching $SETTINGS_PAGE to add SailorHat menu entry"
        # Insert before the last closing brace of the VisibleItemModel block
        PATCH='        \/\/\/\/\/\/\/\/ Sailor Hat\n        MbSubMenu\n        {\n            description: qsTr("SailorHat")\n            subpage: Component { PageSailorHat {} }\n            property VBusItem stateItem: VBusItem { bind: Utils.path("com.victronenergy.sailorhat", "\/State") }\n            show: stateItem.valid\n        }'
        # Use a Python one-liner for reliable in-place editing on busybox
        python3 - "$SETTINGS_PAGE" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    content = f.read()

entry = '''
        //////// Sailor Hat
        MbSubMenu
        {
            description: qsTr("SailorHat")
            subpage: Component { PageSailorHat {} }
            property VBusItem stateItem: VBusItem { bind: Utils.path("com.victronenergy.sailorhat", "/State") }
            show: stateItem.valid
        }
'''

# Insert just before the closing of the VisibleItemModel block
content = re.sub(r'(\s*\}\s*\}\s*)$', entry + r'\1', content, count=1)

with open(path, 'w') as f:
    f.write(content)

print("    PageSettingsGeneral.qml patched.")
PYEOF
    else
        echo "    PageSettingsGeneral.qml already contains SailorHat entry — skipping."
    fi

    echo "--> Restarting GUI"
    svc -t /service/gui
else
    echo "--> GUI v2 or QML dir not found — skipping GUI page install."
    echo "    The daemon will run and publish D-Bus data, but no GUI page will appear."
    echo "    (GUI v2 support requires porting PageSailorHat.qml to the new framework.)"
fi

# --- 5. Status check ---
echo ""
echo "--> Waiting for service to start..."
sleep 3
svstat "$LIVE_SERVICE_DIR"

echo ""
echo "Done."
echo "  Check logs : tail -f /var/log/sh-rpi-venus/current"
echo "  Stop       : svc -d $LIVE_SERVICE_DIR"
echo "  Restart    : svc -t $LIVE_SERVICE_DIR"
echo "  Status     : svstat $LIVE_SERVICE_DIR"

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
GUI_V1_SRC="$REPO_ROOT/GUI/PageSailorHat.qml"
GUI_V1_QML_DIR="/opt/victronenergy/gui/qml"
GUI_V1_SETTINGS_PAGE="$GUI_V1_QML_DIR/PageSettingsGeneral.qml"

GUI_V2_SRC="$REPO_ROOT/GUI/v2/SailorHat_PageSailorHat.qml"
GUI_V2_DIR="/opt/victronenergy/gui-v2"
GUI_V2_PLUGIN_COMPILER="$GUI_V2_DIR/gui-v2-plugin-compiler.py"
GUI_V2_APP_NAME="SailorHat"
GUI_V2_APP_DIR="/data/apps/available/$GUI_V2_APP_NAME"

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

# setuptools>=77 requires packaging>=24.2 — install packaging first so the
# subsequent setuptools upgrade doesn't immediately break.
python3 -m pip install --quiet --upgrade "packaging>=24.2"

# Use --no-build-isolation to avoid pip's isolated build environment, which
# triggers a broken setuptools on Venus OS (missing tomllib in Python 3.12).
# Upgrade setuptools after packaging so it finds the required packaging version.
python3 -m pip install --quiet --upgrade setuptools

# Venus OS Python 3.12 is missing tomllib from stdlib (it was stripped).
# Install the tomli backport (pure Python, always has a wheel) and create a
# compatibility shim so the system setuptools can import it.
if ! python3 -c "import tomllib" 2>/dev/null; then
    echo "    Installing tomllib shim (missing from Venus OS Python 3.12)..."
    python3 -m pip install --quiet tomli
    STDLIB=$(python3 -c "import sysconfig; print(sysconfig.get_path('stdlib'))")
    printf 'from tomli import load, loads\n' > "$STDLIB/tomllib.py"
fi

python3 -m pip install --quiet --no-build-isolation pyyaml smbus2 dateparser typer rich

# aiohttp is imported but the HTTP server is disabled; install it anyway to
# avoid import errors at startup
python3 -m pip install --quiet --no-build-isolation aiohttp

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

# --- 4. GUI page ---
if [ -d "$GUI_V2_DIR" ]; then
    # ---- GUI v2: use the official plugin system ----
    echo "--> Installing GUI v2 plugin"

    if [ ! -f "$GUI_V2_PLUGIN_COMPILER" ]; then
        echo "    WARNING: Plugin compiler not found at $GUI_V2_PLUGIN_COMPILER"
        echo "    Skipping GUI plugin install. Update Venus OS and re-run to install the GUI page."
    else
        mkdir -p "$GUI_V2_APP_DIR/gui-v2"

        # Copy the QML page into the app directory — the compiler expects it there
        cp "$GUI_V2_SRC" "$GUI_V2_APP_DIR/gui-v2/$(basename "$GUI_V2_SRC")"

        # Run the plugin compiler from within the app dir — it writes NAME.json
        # to the current working directory (no --output flag supported)
        ( cd "$GUI_V2_APP_DIR/gui-v2" && python3 "$GUI_V2_PLUGIN_COMPILER" \
            --name "$GUI_V2_APP_NAME" \
            --settings "$(basename "$GUI_V2_SRC")" )

        # Enable the plugin via symlink (idempotent)
        mkdir -p /data/apps/enabled
        ln -sfn "$GUI_V2_APP_DIR" "/data/apps/enabled/$GUI_V2_APP_NAME"

        echo "    GUI v2 plugin installed. Visible under Settings → Integrations → UI Plugins."
        echo "    Note: plugin pages are local display only — not shown in Remote Console."

        echo "--> Restarting GUI"
        if [ -d /service/gui-v2 ]; then
            svc -t /service/gui-v2
        elif [ -d /service/gui ]; then
            svc -t /service/gui
        else
            echo "    WARNING: GUI service not found — restart the GUI manually."
        fi
    fi

elif [ -d "$GUI_V1_QML_DIR" ]; then
    # ---- GUI v1: copy QML and patch PageSettingsGeneral.qml ----
    echo "--> Installing GUI v1 page"
    cp "$GUI_V1_SRC" "$GUI_V1_QML_DIR/PageSailorHat.qml"

    # Add SailorHat menu entry to PageSettingsGeneral.qml if not already present
    if ! grep -q "PageSailorHat" "$GUI_V1_SETTINGS_PAGE" 2>/dev/null; then
        echo "    Patching $GUI_V1_SETTINGS_PAGE to add SailorHat menu entry"
        python3 - "$GUI_V1_SETTINGS_PAGE" <<'PYEOF'
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
    if [ -d /service/gui-v2 ]; then
        svc -t /service/gui-v2
    elif [ -d /service/gui ]; then
        svc -t /service/gui
    else
        echo "    WARNING: GUI service not found — restart the GUI manually."
    fi

else
    echo "--> No GUI installation found — skipping GUI page install."
    echo "    The daemon will run and protect the system without a GUI page."
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

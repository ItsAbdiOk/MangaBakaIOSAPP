#!/bin/bash
# Build and install straight to a paired iPhone over the local network.
#
# For use while TestFlight is unavailable or too slow a loop. Note the
# trade-offs against a TestFlight build:
#   - Debug configuration, not Release
#   - expires after 7 days and must be reinstalled
#   - requires the phone to be paired and reachable from THIS Mac, so it does
#     not work when nobody is at the machine — that is what TestFlight is for
set -euo pipefail

cd "$(dirname "$0")/.."

DEVICE_ID="${1:-}"
if [ -z "$DEVICE_ID" ]; then
    # Pick the first paired iPhone, by deviceType rather than by counting
    # columns: device names contain spaces, so column arithmetic silently
    # returns the wrong field (it returned "iPhone" instead of the UUID).
    xcrun devicectl list devices --json-output /tmp/mangabaka-devices.json >/dev/null 2>&1 || true
    DEVICE_ID=$(python3 -c "
import json, sys
try:
    devices = json.load(open('/tmp/mangabaka-devices.json'))['result']['devices']
except Exception:
    sys.exit(0)
for d in devices:
    if d.get('hardwareProperties', {}).get('deviceType') == 'iPhone':
        print(d['identifier'])
        break
" 2>/dev/null)
fi
if [ -z "$DEVICE_ID" ]; then
    echo "error: no paired iPhone found." >&2
    echo "Connect the phone, unlock it, and make sure it is on the same network." >&2
    xcrun devicectl list devices 2>/dev/null || true
    exit 1
fi
echo "Device: $DEVICE_ID"

DERIVED=/tmp/mangabaka-device-build
echo "Building..."
xcodebuild -project MangaBaka.xcodeproj -scheme MangaBaka \
    -destination "platform=iOS,id=$DEVICE_ID" \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates \
    -quiet build

APP=$(find "$DERIVED/Build/Products" -maxdepth 3 -name "MangaBaka.app" | head -1)
if [ -z "$APP" ]; then
    echo "error: build succeeded but no .app was produced." >&2
    exit 1
fi

echo "Installing $APP..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"

echo
echo "Installed. If it will not open, trust the certificate once on the phone:"
echo "  Settings > General > VPN & Device Management > Apple Development > Trust"

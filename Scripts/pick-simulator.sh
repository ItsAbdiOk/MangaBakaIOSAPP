#!/bin/sh
# Prints the UDID of the simulator to test against, and nothing else.
#
# Why a UDID and not a name: on 2026-09-14 this Mac had TWO devices called
# "iPhone 17 Pro" (iOS 26.5 and iOS 26.3 — a runtime download adds a full set
# of devices under the same names). `-destination "…,name=iPhone 17 Pro"` is
# then ambiguous: xcodebuild picks one without saying which, and when the other
# is mid-shutdown the test host is killed. That is the SIGTERM flake the
# pre-push hook has been hitting. `id=<UDID>` cannot be ambiguous.
#
# Order of preference: a booted device first (no boot cost, and it is the one
# the person is looking at), then the newest runtime, then the highest iPhone
# model number, then "Pro" over the rest.
#
# Usage:  UDID=$(Scripts/pick-simulator.sh) || exit 1
set -eu

xcrun simctl list devices available -j 2>/dev/null | python3 -c '
import json, re, sys

try:
    runtimes = json.load(sys.stdin)["devices"]
except Exception:
    sys.exit(1)

def runtime_key(identifier):
    # "com.apple.CoreSimulator.SimRuntime.iOS-26-5" -> (26, 5)
    match = re.search(r"iOS-([0-9-]+)$", identifier)
    if not match:
        return ()
    return tuple(int(part) for part in match.group(1).split("-"))

best = None
for runtime, devices in runtimes.items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        name = device.get("name", "")
        if not device.get("isAvailable") or not name.startswith("iPhone"):
            continue
        model = re.search(r"iPhone (\d+)", name)
        key = (
            device.get("state") == "Booted",
            runtime_key(runtime),
            int(model.group(1)) if model else 0,
            "Pro" in name,
            # Max last: the smaller Pro is the layout everything was designed
            # against, and a wider screen changes what a UI test can reach.
            "Max" not in name,
            name,
        )
        if best is None or key > best[0]:
            best = (key, device.get("udid"), name, runtime)

if best is None:
    sys.exit(1)
sys.stderr.write("simulator: %s (%s)\n" % (best[2], best[3].rsplit(".", 1)[-1]))
print(best[1])
'

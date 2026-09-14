#!/bin/sh
# Runs the UI / accessibility audit suite and REPORTS SKIPS AS FAILURES.
#
# Why: `XCTSkip` is how these tests cope with "Discover was offline" or "the
# account is signed out", and xcodebuild reports a skipped test the same green
# as a passing one. On 2026-09-13 the Search field became a `.searchable`
# system field; `FlowAffordanceUITests.testSeedPickerDoesNotReturnYouToYourLast
# Search` kept querying `app.textFields`, threw `XCTSkip("no search field")`,
# and nobody noticed for a day because the run stayed green. The test for "that
# endless cycle" had simply stopped running.
#
# A skip is still allowed — the environmental ones are real — but it has to be
# read, not scrolled past. This prints them and exits 2, which is distinct from
# a real failure (1).
#
#   Scripts/run-ui-tests.sh
set -eu

cd "$(dirname "$0")/.."

MB_TMP="${TMPDIR:-/tmp}/mangabaka-uitests"
rm -rf "$MB_TMP"
mkdir -p "$MB_TMP"
BUNDLE="$MB_TMP/ui.xcresult"

UDID=$(Scripts/pick-simulator.sh) || { echo "error: no simulator available." >&2; exit 1; }

echo "Running MangaBakaAccessibility on $UDID (a dozen app launches; a few minutes)..."
status=0
xcodebuild test \
    -project MangaBaka.xcodeproj -scheme MangaBakaAccessibility \
    -destination "platform=iOS Simulator,id=$UDID" \
    -resultBundlePath "$BUNDLE" \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 180 \
    >"$MB_TMP/ui.log" 2>&1 || status=$?

if [ "$status" -ne 0 ]; then
    echo "UI tests FAILED:" >&2
    grep -E "✘|error:|XCTAssert|Test run with" "$MB_TMP/ui.log" | head -25 >&2
    echo "  full log: $MB_TMP/ui.log" >&2
    exit 1
fi

# `xcresulttool get test-results tests` is the supported reader; the log text is
# a fallback for an Xcode whose JSON shape differs.
SKIPS=$(xcrun xcresulttool get test-results tests --path "$BUNDLE" 2>/dev/null \
        | python3 -c '
import json, sys
try:
    tree = json.load(sys.stdin)
except Exception:
    sys.exit(0)

def walk(node, trail):
    name = node.get("name", "")
    here = trail + [name] if name else trail
    if node.get("result") == "Skipped":
        print(" / ".join(here))
    for child in node.get("children", []) or []:
        walk(child, here)

for node in tree.get("testNodes", []) or []:
    walk(node, [])
' 2>/dev/null) || SKIPS=""

if [ -z "$SKIPS" ]; then
    SKIPS=$(grep -E "Test case .* was skipped|XCTSkip" "$MB_TMP/ui.log" | head -20 || true)
fi

if [ -n "$SKIPS" ]; then
    echo
    echo "UI tests passed, but these did not run:"
    echo "$SKIPS" | sed 's/^/  skipped: /'
    echo
    echo "Each of these asserted nothing. If the reason is environmental"
    echo "(offline, signed out) that is fine; if it is a query that no longer"
    echo "matches the UI, the test has been dead since the UI changed."
    echo "  result bundle: $BUNDLE"
    exit 2
fi

echo "UI tests passed, nothing skipped."

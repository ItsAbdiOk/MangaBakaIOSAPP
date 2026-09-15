#!/bin/sh
# Xcode Cloud runs this after every xcodebuild action. On the archive it
# writes TestFlight's "What to Test" from the commit subject, so each build's
# card on the phone says what changed.
#
# Why this and not the API: TestFlight showed builds 81 and 82 as identical
# "0.1.0" cards on 2026-09-14, and `Scripts/asc.py notes` had to be run by
# hand after each one. Xcode Cloud reads `TestFlight/WhatToTest.<locale>.txt`
# beside the archive and needs no key for it — Apple's documented mechanism
# (Xcode Cloud → "Including notes for testers with a beta release of your
# app"). The locale must be one the app's TestFlight test information
# carries; ours is en-GB only.
#
# On the test action it prints the skip count instead. Fifty-five test files
# read the app's own source (`SourceTree.isAvailable`) and skip where there is
# no checkout to read, which is here; they run on every developer Mac and in
# the pre-push hook, so nothing reaches `main` untested. Abdi's call,
# 2026-09-15: accept the skip and make it visible rather than ship the
# sources inside the test bundle.
set -eu

if [ "${CI_XCODEBUILD_ACTION:-}" = "test-without-building" ] || [ "${CI_XCODEBUILD_ACTION:-}" = "test" ]; then
    if [ -n "${CI_RESULT_BUNDLE_PATH:-}" ] && [ -e "$CI_RESULT_BUNDLE_PATH" ]; then
        summary=$(xcrun xcresulttool get test-results summary --path "$CI_RESULT_BUNDLE_PATH" 2>/dev/null || true)
        skipped=$(printf '%s' "$summary" | sed -n 's/.*"skippedTests" *: *\([0-9]*\).*/\1/p' | head -1)
        echo "Skipped tests in this cloud run: ${skipped:-unknown} (source-reading tests skip without a checkout; the pre-push hook runs them)."
    else
        echo "No result bundle to count skips from."
    fi
    exit 0
fi

if [ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]; then
    exit 0
fi

# Same guard as ci_pre_xcodebuild.sh: a phase with no checkout exits cleanly.
if [ -z "${CI_PRIMARY_REPOSITORY_PATH:-}" ] || [ -z "${CI_APP_STORE_SIGNED_APP_PATH:-}" ]; then
    echo "No checkout or no signed app in this phase; nothing to annotate."
    exit 0
fi

subject=$(git -C "$CI_PRIMARY_REPOSITORY_PATH" log -1 --format=%s)
# Apple's documented location: a `TestFlight` folder at the repository root
# (their example writes to `../TestFlight` from the `ci_scripts` cwd). The
# first version put it beside the signed app; build 84 (2026-09-15) shipped
# with no note and proved that wrong.
notes_dir="$CI_PRIMARY_REPOSITORY_PATH/TestFlight"
mkdir -p "$notes_dir"
printf '%s\n' "$subject" > "$notes_dir/WhatToTest.en-GB.txt"
echo "What to Test: $subject"

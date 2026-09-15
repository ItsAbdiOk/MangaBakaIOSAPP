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
# Not run on the test action: there is no archive to annotate, and the file
# would be written somewhere nothing reads.
set -eu

if [ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]; then
    exit 0
fi

# Same guard as ci_pre_xcodebuild.sh: a phase with no checkout exits cleanly.
if [ -z "${CI_PRIMARY_REPOSITORY_PATH:-}" ] || [ -z "${CI_APP_STORE_SIGNED_APP_PATH:-}" ]; then
    echo "No checkout or no signed app in this phase; nothing to annotate."
    exit 0
fi

subject=$(git -C "$CI_PRIMARY_REPOSITORY_PATH" log -1 --format=%s)
notes_dir="$CI_APP_STORE_SIGNED_APP_PATH/../TestFlight"
mkdir -p "$notes_dir"
printf '%s\n' "$subject" > "$notes_dir/WhatToTest.en-GB.txt"
echo "What to Test: $subject"

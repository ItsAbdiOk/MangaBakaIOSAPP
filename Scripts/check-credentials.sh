#!/bin/sh
# The one credential check. Called by .githooks/pre-push and by
# ci_scripts/ci_pre_xcodebuild.sh.
#
# It exists as a file because it used to exist twice, with DIFFERENT scopes:
# the hook checked every tracked file, CI checked only MangaBaka/*.swift. The
# all-tracked-files check is the one that matters — a real token was once
# pasted into Configs/Secrets.example.xcconfig, which is tracked and is not
# Swift, and the Swift-only check would not have caught it. CI had the weaker
# half. That is the n-1 pattern in the security check itself.
#
# Exit 0 clean, 1 with a finding. Prints its own errors.
set -eu

cd "$(dirname "$0")/.."

found=0
note() { echo "error: $1" >&2; found=1; }

# 1. The real secrets file must never be tracked.
if git rev-parse --git-dir >/dev/null 2>&1; then
    if git ls-files --error-unmatch Configs/Secrets.xcconfig >/dev/null 2>&1; then
        note "Configs/Secrets.xcconfig is tracked by git. It must stay local."
    fi
elif [ -f Configs/Secrets.xcconfig ]; then
    # No git (an Xcode Cloud phase with an exported checkout): presence is the
    # only signal available, and the file should not be in a build at all.
    note "Configs/Secrets.xcconfig is present in the repository."
fi

# 2. A token-shaped literal in shipping code.
#
# **`{10,}`, and it must stay in step with `TokenStore.looksValid`**, which
# accepts `mb-` plus a total length over 12 — so the shortest token the app
# itself will store has a ten-character suffix. This said `{16,}`, which left
# every 13-to-18-character token invisible to the scanner while the app
# accepted it happily: the check and the thing it checks disagreed about what
# a token is (review item 72, 2026-09-14). `TokenStoreCacheTests` pins the two
# numbers against each other, because a shell script cannot read a Swift
# constant and copying it here is how they drifted the first time.
#
# `MB_SUFFIX` is the ten. Named once so the four greps below cannot drift from
# each other the way this one drifted from Swift.
MB_SUFFIX='mb-[A-Za-z0-9]{10,}'
# Excluded: `mb-xxxxxxxxxxx`, the placeholder MangaBaka's own OpenAPI document
# uses ~40 times in docs/schemas. It only became a match at `{10,}`. Matched on
# an all-`x` suffix rather than by excluding the directory, so a real token
# pasted into a vendored file is still caught.
MB_PLACEHOLDER='mb-x+([^A-Za-z0-9]|$)'
if git rev-parse --git-dir >/dev/null 2>&1; then
    if git grep -nE "\"$MB_SUFFIX\"" -- 'MangaBaka/*.swift' 2>/dev/null \
        | grep -vE "$MB_PLACEHOLDER" | grep -q .; then
        note "a token-shaped literal is present in shipping code."
    fi
    # 3. Any tracked file, not just Swift. Tests are excluded because their
    #    fixtures carry deliberately fake token-shaped strings.
    if git grep -nE "$MB_SUFFIX" -- . ':(exclude)*Tests*' 2>/dev/null \
        | grep -vE "$MB_PLACEHOLDER" | grep -q .; then
        note "a token-shaped string is present in a tracked file. Move it to Configs/Secrets.xcconfig."
    fi
else
    if grep -rEn "\"$MB_SUFFIX\"" MangaBaka --include='*.swift' 2>/dev/null \
        | grep -vE "$MB_PLACEHOLDER" | grep -q .; then
        note "a token-shaped literal is present in shipping code."
    fi
    if grep -rEn "$MB_SUFFIX" . \
        --exclude-dir=.git --exclude-dir='*Tests*' 2>/dev/null \
        | grep -vE "$MB_PLACEHOLDER" | grep -q .; then
        note "a token-shaped string is present in a checked-out file."
    fi
fi

[ "$found" -eq 0 ] || exit 1
echo "  no credentials committed."

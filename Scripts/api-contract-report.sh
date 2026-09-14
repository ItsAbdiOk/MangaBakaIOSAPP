#!/bin/sh
# Runs both wire-shape tools and leaves a dated report behind.
#
# Why this exists: `check-api-contract.py` and `api-shape-sweep.py` are the two
# tools built for the failure mode that has cost this project the most — the
# API's shape changing while every unit test keeps passing against a frozen
# fixture — and as of the 2026-09-14 review NEITHER HAD A CALLER. Not in the
# pre-push hook, not in ci_scripts/, on no schedule; the only mention of either
# was one line of README. The one tool aimed at the charter's first pattern
# never ran.
#
# Deliberately NOT wired into .githooks/pre-push. The hook is already ~10
# minutes and this makes live network requests: a push would then fail because
# somebody's wifi dropped, which is the fastest way to teach people to use
# --no-verify. Run it on a schedule or by hand instead.
#
#   Scripts/api-contract-report.sh            # contract check only
#   MB_TOKEN=... Scripts/api-contract-report.sh   # and the authenticated sweep
#
# Exit 0 clean, 1 a field the app relies on is gone, 2 could not reach the API.
set -eu

cd "$(dirname "$0")/.."

STAMP=$(date -u +%Y-%m-%d)
OUT="docs/api-contract-$STAMP.txt"
mkdir -p docs

{
    echo "MangaBaka wire-shape report"
    echo "generated $(date -u '+%Y-%m-%d %H:%M UTC') by Scripts/api-contract-report.sh"
    echo
    echo "== Fixture contract check =="
} >"$OUT"

status=0
python3 Scripts/check-api-contract.py >>"$OUT" 2>&1 || status=$?

{
    echo
    echo "== Type-divergence sweep =="
} >>"$OUT"

if [ -n "${MB_TOKEN:-}" ]; then
    # The sweep hits /v1/my/library, so it needs the token and its output can
    # carry account-shaped data. Types only are written here, never values —
    # that is the sweep's own design — but keep the raw JSON out of docs/.
    SWEEP_RAW="${TMPDIR:-/tmp}/mangabaka-sweep-$STAMP.json"
    python3 Scripts/api-shape-sweep.py "$SWEEP_RAW" >>"$OUT" 2>&1 || status=$?
    echo "  raw shapes: $SWEEP_RAW (not committed)" >>"$OUT"
else
    echo "skipped: MB_TOKEN is not set, and the sweep's endpoints include /v1/my/library." >>"$OUT"
fi

cat "$OUT"
echo
echo "Report written to $OUT"
exit "$status"

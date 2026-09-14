#!/bin/sh
# launchd entry point for the weekly API-contract check
# (Scripts/api-contract-report.sh). Installed by hand — see
# Scripts/README-api-contract.md — never automatically.
#
# This runs unattended on Abdi's schedule with nobody watching stdout, so it
# decides what deserves a human's attention instead of just logging:
#
#   - No network: skip the whole run, silently. A missed week costs nothing;
#     a "check failed" notification every time the laptop is off wifi trains
#     Abdi to ignore this job's notifications, which defeats the point.
#   - Clean run (exit 0, nothing moved): stay silent. The dated report is
#     still written to docs/ by api-contract-report.sh for the record — this
#     wrapper's silence is about not nagging, not about suppressing that file.
#   - Real API-shape change (exit 1): the one outcome worth surfacing.
#   - Could-not-reach-the-API despite a network link (exit 2, e.g. the API is
#     down or rate-limiting): treated the same as "no network" — transient,
#     not something to wake anyone up for.
#
# Always exits 0 itself: a scheduled agent whose script "fails" gets flagged
# by launchd/log, and this job's actual failure mode (wifi, or MangaBaka
# being briefly down) is not the thing anyone should be paged for.
set -u

cd "$(dirname "$0")/.."

LOG="$HOME/Library/Logs/mangabaka-api-contract.log"
mkdir -p "$(dirname "$LOG")"

log() {
    printf '%s %s\n' "$(date -u '+%Y-%m-%d %H:%M UTC')" "$1" >>"$LOG"
}

# Reachability probe against Apple's own captive-portal check endpoint, not
# api.mangabaka.org: this must cost the MangaBaka API zero requests when the
# answer is "no network" or "network's fine but MangaBaka is down" — either
# way check-api-contract.py's own request budget (one call per manifest
# endpoint) is the only thing that should ever hit their server.
if ! curl -s --max-time 4 -o /dev/null "http://captive.apple.com/hotspot-detect.html"; then
    log "skipped: no network"
    exit 0
fi

OUTPUT=$(Scripts/api-contract-report.sh 2>&1)
status=$?

case "$status" in
    0)
        log "clean: no shape change"
        ;;
    1)
        log "CONTRACT CHANGE DETECTED -- see docs/api-contract-*.txt"
        # display notification is the one deliberately noisy line in this
        # script: everything else here is designed to stay quiet.
        osascript -e 'display notification "A MangaBaka API field changed shape - see docs/api-contract-*.txt" with title "API contract check"' >/dev/null 2>&1 || true
        ;;
    2)
        log "skipped: API unreachable despite network (transient, not alarming)"
        ;;
    *)
        log "unexpected exit status $status"
        ;;
esac

printf '%s\n' "$OUTPUT" >>"$LOG"
exit 0

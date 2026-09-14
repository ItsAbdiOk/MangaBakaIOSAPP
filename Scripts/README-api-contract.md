# API contract check — scheduling

`Scripts/check-api-contract.py` and `Scripts/api-shape-sweep.py` are the
tools that catch MangaBaka's API changing shape under a frozen test fixture —
the failure class that has shipped four bugs. `Scripts/api-contract-report.sh`
runs both and writes a dated report. None of this has a caller: it is not in
the pre-push hook (deliberately — see the comment at the top of
`api-contract-report.sh`) and there was no schedule at all until this file.

## What's here

- `api-contract-schedule.sh` — the launchd entry point. Skips the run
  silently if there's no network, runs `api-contract-report.sh`, and only
  raises a macOS notification if a fixture's shape actually changed (exit 1).
  A clean run or a transient "couldn't reach the API" (exit 2) is logged to
  `~/Library/Logs/mangabaka-api-contract.log` and nothing more.
- `org.mangabaka.api-contract-check.plist` — a launchd **user agent**
  definition, weekly (Sunday 10:00 local time — edit
  `StartCalendarInterval` in the plist to change it). **Not installed by
  this repo or by anything automatic** — you install it yourself, once.

## Install

```sh
launchctl bootstrap gui/$(id -u) /Users/abdi/Code/MangaBakaIOSAPP/Scripts/org.mangabaka.api-contract-check.plist
```

This registers the job for your current login session; it survives logout/
login and reboot (launchd reloads it from the same path each time you log
in — the plist is not copied into `~/Library/LaunchAgents`, so don't move or
delete this file from the repo checkout without unloading the job first).

## Check it's installed and ran

```sh
# Is it loaded, and what was the last/next run?
launchctl print gui/$(id -u)/org.mangabaka.api-contract-check

# Wrapper's own log (quiet by design — a clean week is one line)
tail -20 ~/Library/Logs/mangabaka-api-contract.log

# launchd-level log (should stay almost empty; anything here means the
# shell itself failed to start, not that the contract check found something)
cat ~/Library/Logs/mangabaka-api-contract.launchd.log

# This week's actual report, if one exists
ls docs/api-contract-*.txt
```

To run it right now instead of waiting for Sunday:

```sh
launchctl kickstart gui/$(id -u)/org.mangabaka.api-contract-check
```

## Uninstall

```sh
launchctl bootout gui/$(id -u)/org.mangabaka.api-contract-check
```

## Network and rate-limit behavior

- The wrapper probes `captive.apple.com` (Apple's own connectivity-check
  endpoint) before doing anything else, so a "no network" week costs the
  MangaBaka API zero requests and produces zero noise.
- `check-api-contract.py` makes one request per manifest entry in
  `api-contract-endpoints.json` (four, as of 2026-09-14). `api-shape-sweep.py`
  only runs if `MB_TOKEN` is set in the environment the launchd job inherits
  (it isn't, by default — the sweep hits `/v1/my/library`, personal data,
  which is exactly why `api-contract-report.sh` gates it behind that env
  var). Nobody should set `MB_TOKEN` in the plist itself: `ProgramArguments`
  and `EnvironmentVariables` in an installed `.plist` are readable by any
  process that can run `launchctl print`, which is a worse place for a
  personal access token than the keychain.
- Neither script retries on failure or loops; a missed week from a laptop
  that was asleep at 10:00 Sunday just waits for the next one.

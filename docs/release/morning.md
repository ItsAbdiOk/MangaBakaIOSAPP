# Morning — 2026-09-15

Written first, before the night's work, and appended to as it goes. If this
file stops mid-list, the session ran out of context; everything above the
last entry is committed.

## The short version

Nine commits overnight, all tested (2,240 tests on iOS 27, lint, unsigned
Release archive), pushed at the end if the last line of this file says so.
Nothing needed a sign-in. Two things did not happen: a screenshot walk of the
app on iOS 27 (the simulator tool crashed with the Xcode update — the XCUI
audit ran instead), and the phone (locked by the time it was mine).

## Needs you

- **Push.** Everything below is committed locally, not pushed, unless the
  last line of this file says "pushed".
- ~~Start build 84~~ — resolved: the 05:2x push triggered run 84 on its
  own, so the missed run for `6e9b59f` was a one-off on Apple's side, not
  the workflow. If 84 fails, `python3 scripts/asc.py why` has the reason.
- App Store screenshots: six frames on the Desktop. Decide whether to
  frame them (bezel + caption) or upload bare; the Search frame should be
  re-shot showing results, the Mix frame with seeds — both are a small
  change to `MangaBakaUITests/ScreenshotCaptureTests.swift`.
- `docs/reviews/open-items-2026-09-15.md` has four items that are your
  call (`.mix schema=full`, notification deferral policy, the Xcode Cloud
  source-tree gate, four NDL wording choices).
- The next build's TestFlight note will come from the commit subject
  automatically (`ci_scripts/ci_post_xcodebuild.sh`) — no key needed; check
  it worked on build 84/85 and `asc.py notes` can retire.

## Done overnight (newest last)

- 00:1x Xcode 27 / iOS 27 SDK: clean build, no deprecations, 2,189 tests green on an iOS 27 sim. Pin bumped.
- Onboarding: Skip/Next were 29x16 pt tap targets (audit measured); now 44, Skip contrast raised. UI tests skip onboarding via launch argument — the whole a11y audit had been measuring the carousel.
- Night review (persistence): retry of the library move could overwrite a fresher walk — guarded by cachedAt; signed-out launch now clears all three widget tiles; VACUUM retried if the file is bloated; schema-drift test covers the moved pair; version pair spelled once in project.yml.
- Widget snapshot reads volumes for the whole library in one query, not one per entry.
- `ci_scripts/ci_post_xcodebuild.sh`: What to Test = commit subject, via Apple's TestFlight/WhatToTest file — no ASC key needed after all. Drop that item from your list.
- 02:5x Committed d3821bc: night review fixes (shelf: 特装版 shelves, 外伝 work titles, format-grouped shelves, partial NDL pages honest, ANN hrefs safe; persistence: retry can't overwrite a fresher walk, sign-out clears all tiles, VACUUM retried). Found + fixed on the way: Apothecary "Releases" failure (Webtoons client asked about every link), inert cast Retry, Omniscient novel page empty, three real a11y findings. 2,211 tests, archive clean.
- Sim MCP tool crashed with the Xcode update and cannot be restarted from here — the iOS 27 screen walk (item 2) was replaced by the XCUI audit run; a screenshot walk needs the panel reopened by you. Similar-by-description coverless cards (item 7): by design and captioned — cover URLs are content-hashed, not derivable; nothing to fix.
- 04:0x Committed: widget now reads persisted edition answers (whole library, 30-day window); review ledger reconciled → docs/reviews/open-items-2026-09-15.md; `+` in queries fixed; search Save patches the Library tab; cast Retry no longer inert. 2,223 tests.
- 04:3x Coverage (xccov, iOS 27): app 41.1% by line, **Core 90.0%** — the uncovered 59% is SwiftUI views. Only Core gap worth a test: NDLClient's network path (33.6%) — tests in progress. Open Library covers re-measured on 5 series: 2 of 6 clear 50%, three are 0% → stays unwired (docs/sources/bibliographic.md).
- Tag tree: removed the "include sub-tags" toggle — it changed the number on the Browse button, never the search (no tag-OR on the API). Category nodes (own count 0) now say "pick a sub-tag" instead of offering a Browse that answers nothing.
- 05:0x App Store screenshots: six 1320×2868 frames, no real art, in ~/Desktop/MangaBaka-screenshots/ (docs/release/screenshots.md says what a second pass should change). Performance scheme had been silently uncompilable since 09-14 — fixed and folded into the main test run (adds <4 s). All 14 measures fast.
- 05:2x **pushed** `6e9b59f..ea3cf2a` (11 commits). Watching whether Xcode Cloud picks this one up — if a run for `ea3cf2a` appears, last night's missing build 84 was a one-off; if not, the trigger is broken (see "Needs you").
- 06:1x Build 84 SUCCEEDED and is processed (1.1.0, under Friends via the post-action). Its TestFlight note came through **empty** — the ci script wrote the file beside the signed app; Apple reads `TestFlight/` at the repo root. Fixed (6ef64ac, committed, not pushed — it rides with the next push) and 84's note set by hand. Build 85 is the real test of the script.

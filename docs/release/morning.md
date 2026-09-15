# Morning — 2026-09-15

Written first, before the night's work, and appended to as it goes. If this
file stops mid-list, the session ran out of context; everything above the
last entry is committed.

## Needs you

- **Push.** Everything below is committed locally, not pushed, unless the
  last line of this file says "pushed".
- **Start build 84** (or whichever number is next) in App Store Connect →
  Xcode Cloud → TestFlight → Start Build, on `main`. The push of `6e9b59f`
  at 21:38 on 2026-09-14 never triggered a run; it was the first push after
  Chrome saved the workflow with "Restrict Editing" on. If the morning push
  triggers a run by itself, that was a one-off miss; if not, the trigger is
  broken and needs a look at the workflow.
- The ASC key for Xcode Cloud (so `ci_post_xcodebuild.sh` can set release
  notes) — see the ci_scripts entry below once it exists.

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

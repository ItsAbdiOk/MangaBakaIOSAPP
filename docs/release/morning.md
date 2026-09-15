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

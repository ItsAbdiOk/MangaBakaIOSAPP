# The deep review, fixed — 2026-09-11

What happened after the deep review (`docs/reviews/SUMMARY.md`), in the order you set: fix it
all, then the feel of the app, then ship. 64 commits, one per finding or one per
feel step, each with the failing test in its message where a test could see it.

## The numbers

- Tests: 720 → 780, 152 → 161 suites. Unit, accessibility/UI and performance
  schemes all green at the push.
- Findings fixed: everything in the handoff's ranked list, plus the tail of the
  review table — 55 commits' worth. Three withdrawn as false positives (W15,
  P-F6, the badge contrast), recorded in code so they stay withdrawn.
- Accessibility audit: 75 → 78 expected issues. The difference is the corrected
  "All" count (same flag, right number), plus three of the two classes the H2
  investigation already showed are not real — text at a horizontal row's
  viewport edge, and text under the tab-bar glass. Nothing new in kind.
- Measured, before and after: the library's body pass went from 0.86 ms to 9 µs
  a pass; the launch path we own is 2–10 ms of Apple's 400 ms (so dyld work is a
  negative result and not worth starting).

## What you will notice

- **Reminders fire.** Neither of the two library nudges had ever reached a lock
  screen: they were re-set to "tomorrow" on every launch. And a chapter due this
  afternoon was scheduled for nine this morning. Both fixed; "out today" fires
  on the day now.
- **Offline is offline.** The library said "Nothing saved yet" to a 937-series
  reader; the schedule said "0 in scope" and deleted every pending reminder.
  Both now say what happened and keep what they had.
- **The stack tells you where a save went** ("Saved to your library" / "Saved
  here") and where the cards came from. The next card lands the instant you
  throw one, not when the write returns.
- **Long-press a library row to edit it.** The edit affordance had been lost in
  the redesign.
- **Numbers are honest**: "All 511" not "All 937"; the dropped sentence carries
  your share, not the reference account's; Wrapped counts only what you read;
  "From 13 gaps between releases" instead of a count of days.
- **Covers download at the size they are drawn** — a 52pt thumbnail was
  fetching 3.7× the pixels.
- **The feel pass** — motion explains, haptics confirm: every commitment has a haptic;
  every button answers the finger; numbers count instead of cutting; every
  series page grows out of the cover you tapped (was Discover only); cover rows
  arrive and snap; symbols react; loading shimmers in the shape of the answer.
  All of it reads Reduce Motion.

## Corrections owed

- I saved "The Price Is Your Everything" to your real library (plan to read)
  while checking the stack on the simulator. Remove it if you don't want it.
- The test suite was writing a fake account id into the app's own UserDefaults
  on the simulator, which made one manual check lie (an empty cache). Fixed;
  the tests have their own suite now. Production never saw it.
- The OpenAPI spec was in the repo all along. I probed the live API for a night.

## Yours to decide

- `ShelfDetailView`: delete or re-wire. Unreachable; its edit affordance is
  now on the live list too.
- Two rating scales (out of 5 in Library, out of 10 in Wrapped).
- The A–Z jump index at 20×13pt per letter is a redesign, not a fix.
- Whether `.claude/skills/deep-review/` should be tracked (it is gitignored).

Everything else left is listed with its reason in `docs/todo-next-week.md`.

Not done from the feel plan, deliberately: the tab icons' `.replace` (the system
tab bar draws them), an end-of-feed haptic on Discover (would fire on scroll, not
on an action), and the cover gallery zooming from the tapped cover (a sheet, a
different transition family).

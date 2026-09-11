# The overnight run — what happened

31 commits on `main`, one branch, one push. Everything below was verified
before it was committed: 686 tests, `swiftlint --strict` clean, and the
simulator or the phone looked at wherever the change was visible.

## The eight things worth knowing

1. **The release calendar has never once worked.** `UpcomingWork.price` was a
   `String`; the API sends a list of `{value, iso_code}`. Every real response
   threw on decode, the throw is caught and read as "no upcoming works", and
   the announced-releases section — the only part of the schedule that is a
   fact rather than an estimate — has been empty since it was built. The test
   fixture said `String` too, so the suite agreed with the bug.

2. **Entering a different token never forgot the previous account.** The
   cached profile id and the whole taste ledger stayed, and the ledger is on
   disk, so every recommendation afterwards was quietly built from somebody
   else's reading. Both `forgetProfile()` and `clear()` existed, documented
   for exactly this, and nothing called either. Periphery reported them as
   dead code.

3. **Every bare cover was silent to VoiceOver.**
   `CoverImage.accessibilityText` was declared, commented "without this a
   reader using VoiceOver hears nothing at all", passed in at every call site
   — and never applied to the view.

4. **The accessibility audit had never been on the series page.** It tapped
   the first button on Discover, which is the "Open the stack" card, and filed
   the Stack's issues under "Series detail". Found by looking at the
   screenshot the audit now saves of itself.

5. **Most of the 47 contrast failures were not real.** Reproduced by recording
   each issue's frame and the screen as the audit saw it, then sampling the
   pixels: the majority are elements the audit walked but the screen never
   showed — "Hidden gems" sits at y=861 on an 852pt screen. The plan to raise
   76 places off `textQuaternary` was answering the wrong question.

6. **A whole screen has no way into it.** `ShelfDetailView` exists, is tested,
   and has a navigation destination waiting; nothing presents it. **This one
   needs you** — see below.

7. **The app now has a scroll edge**, which was the worst-looking defect on
   the phone, and the series page no longer prints its title twice.

8. **The Apple branch is built and can be run.** `git checkout apple-idiomatic`.
   Screenshots and an honest comparison in `docs/apple-experiment/README.md`.

## What needs you

- **Shelf detail: delete it or wire it back up?** A product decision, not a
  bug fix. Both options and their costs are in
  `docs/unknowns-2026-09-11.md`. Nothing was changed; the audit test for that
  screen skips with the reason printed, so the question stays visible.
- **The public shareable stats page still needs designing.** You wanted to use
  Claude Design for it. This is the reminder you asked for.
- **Tachimanga backup import**, so the app can learn real reading speed
  instead of the published-average guess (manhwa 6 min, novel 20, default 11 —
  labelled a guess in `ReadingInsights`). Needs the backup format
  investigating and probably a design.
- **Per-series volumes.** `/v1/series/{id}/works` exists and is good: 25
  volumes for Solo Leveling with dates, prices, page counts, ISBNs and
  per-volume cover art. Not built, because it is a volume grid and that is a
  design question. One trap written down for whoever lays it out: each volume
  appears twice, paperback and hardcover, told apart only by price and ISBN.
- **Custom lists do not exist in the public API.** `/v1/my/lists`,
  `/v0/my/lists` and `/v1/lists` all 404, and the OpenAPI spec is not served
  anywhere documented. Worth asking MangaBaka directly rather than guessing at
  more paths.

## What was left undone, and why

- **Cold launch (~900 ms).** 598-634 ms of it is framework and linker work
  before any of our code runs. The lever is needing less at launch, which is a
  real project rather than a fix.
- **`TasteProfile` and `ReleaseReminders` coverage.** Not attempted.
- **`ReleaseSchedule`'s actor I/O.** Needs a database fixture and a fake
  MangaUpdates client — worth building, not worth rushing at 3am.

## Where everything is

- The findings list was `docs/findings-todo.md`; closed out and deleted on
  2026-09-11, the commits `6c2a89b..3660c77` carry each item's evidence.
- `docs/unknowns-2026-09-11.md` — all six unknowns, with their evidence.
- `docs/apple-experiment/` — the Apple branch's screenshots and write-up.
- `docs/periphery-2026-09-11.txt` — the full dead-code report.
- `docs/designs/api-opportunities.md` — updated with tonight's API findings.

# Open items — reconciled 2026-09-15

Every finding in `docs/reviews/SUMMARY.md` (77), `docs/reviews/full/SUMMARY.md`
(138 + Q1–Q13 + 18 do-not-fix) and `docs/reviews/full2/SUMMARY.md` (lanes
A–E) was checked against the code at `d3821bc` by reading the file, not the
commit message. Result: **~230 done, 8 superseded by later deletions
(Naver, the nudge machinery, TranslationGap), and the list below still
open.** One "still open" claim from a verifier was wrong — CSV formula
defusing (`LibraryExport.defused`, work-list 91) has been in place since
7a9779f with a round-trip test — so each line here was re-read before it
was kept.

Fixed tonight while reconciling (so not listed): W7 `+` in query values
(now `%2B`, test); 72c a Save from search patches the shared library model;
three stale comments (RemindersSection, LibraryModel, SessionTests title).

## Needs a decision from Abdi

| Item | Source | What | Why it waits |
|---|---|---|---|
| ~~`.mix` with `schema=full`~~ | full2 work-list 19, decision 4 | Resolved 2026-09-15, no decision needed | Re-measured live: `schema` is still rejected (400, "Unrecognized key"), **but `/v1/series/mix` already answers the full 36-field series** — `description` and all — without it. There was never anything to turn on. |
| Deferred-notification shelf life | full2 decision 6 | Defer only condition 2 (new chapter) past 14 days, never 1b (a release the reader is waiting for) | Policy, not code. `NotificationPolicy` has no per-condition deferral flag. |
| Xcode Cloud source-tree gate | full2 work-list 60 | Source-reading tests skip silently in the cloud (no checkout in the test phase) | Either ship the sources into the test bundle (project.yml `resources`) or accept the skip and print its count. |
| NDL 近刊 title mismatch, orphan "erase N" wording, publisher-less 近刊 shelf, `外伝　01` shelf name | `docs/reviews/night/shelf.md` "Needs Abdi" | Copy and grouping choices on the volumes shelf | Each is a wording call on real data. |

## Open, no decision needed — by value

| Item | Source | Effort | Note |
|---|---|---|---|
| Token save does not rebuild account surfaces | full2 work-list 14 | a function | `SettingsView.save()` clears the previous account and checks the token; nothing re-walks library/reminders/Spotlight for the new one until the next launch. |
| `LibraryImport` request spacing | full2 work-list 37 | a function | Sleeps once per row, but an `add` then `update` on one row go back-to-back. |
| `TasteRanker.rank` scores per comparison | full2 work-list 49 | a function | Decorate-sort-undecorate; unmeasured cost on 945 entries. |
| `TasteProfile.note` scans the whole library | full2 work-list 68 | a line | A `LibrarySnapshot.entry(for:)`; mostly hits the in-memory fast path today. |
| `OfflineCatalogue.titles(for:)` decodes the whole index | full2 work-list 76 | a function | 1.48→4.75 MB gunzip + full decode to label neighbours; an id-keyed sidecar. |
| `appleUnreachable` blame ordering | full2 work-list 59 | a function | Home store answers `[]`, Japanese fallback fails → the failure is reported over the valid empty answer. |
| Seven file-cache implementations | full2 work-list 115 | a file | One `VersionedFileCache`; "not urgent" in the original. |
| Recommendations fixture | full2 work-list 128 | an hour | `RecommendationQualityTests` hand-types JSON; capture one real `/v1/my/recommendations` page (needs a token — Abdi's machine). |
| Real sleeps in two tests | full2 work-list 129 | an hour | `TagSearchTests:144`, `RequestBudgetTests:138/141` — models take a clock; the tests don't use it. |
| Throwing-database test for `ReleaseSchedule` | full2 work-list 136 | an hour | ~10 `try?` sites with no test that a write failure is surfaced. |
| `Clock` → `CacheClock` rename | full2 work-list 72 | mechanical, 162 references | Collides with `_Concurrency.Clock` — every new file has to qualify it. |
| `Metrics.scrollBottomInset` 124 / `SettingsRow` 63 | full2 work-list 101 | a measurement | Unresolved since 09-13; the a11y triage tonight hit it again ("ch NN" under the tab bar). |
| GigaViewer back-off window untested | SUMMARY F18 (65) | an hour | The test proves a 429 fails; not that the next request waits. |
| `tonarinoyj.rss` fixture unused | SUMMARY F11 (30) | an hour | Captured 09-13, still unreferenced; `GigaViewerFeedTests` uses a hand-shaped one. |
| Nested `[spoiler]` in Shikimori | SUMMARY T6/F16 (49) | a function | Non-greedy regex closes at the first `[/spoiler]`. |
| 113 raw-string assertions | SUMMARY F19 (66) | half a day | Held back on purpose 09-13; still the biggest "tests agree with the bug" surface. |

## Recorded, not planned

- Korean digital-first webtoons: no lawful next-episode source
  (`docs/sources/webtoon-episodes.md`, 0 of 14). The MangaUpdates
  original-run line shipped in its place.
- Open Library covers for coverless ANN rows: 1 of 9 on Omniscient Reader;
  re-measure on five series before wiring.

## The three that remain, plainly — answered 2026-09-15

Abdi's answers, in his words, then what was done:

1. **"NOTIFICATIONS ONLY FOR FINISHED OR SEASON ENDING OR SERIES THAT HAVE
   JUST COME BACK FROM HIATUS."** A new rule, not an answer to the deferral
   question — it removes the release notifications that raised it. Conditions
   1a (volume out today) and 1b (new episode) deleted from `NotificationPolicy`;
   a "back from hiatus" condition added (status was `hiatus`, now anything but
   hiatus/completed/cancelled, same baseline rule as "finished"). Ten
   pacing/dedup tests that used releases as their vehicle rewritten on the
   finished/back facts.
2. **"I'll take your recommendations"** — (a). `ci_post_xcodebuild.sh` prints
   the skipped-test count from the result bundle on the cloud's test action.
3. **"I'll do all your recommendations"** —
   - (i) done: an ISBN-less NDL row with a number is keyed `ndl:<shelf>:<n>`
     (`OwnedVolumeKey`); `reconcile` also moves a tick written under the old
     `row:` key.
   - (ii) **moot**: there is no "Erase N ticks" control in Settings —
     `OwnedVolumes.count()` exists and nothing calls it. When one is built,
     the wording is "N ticks (some may be for volumes no longer listed)".
   - (iii) done: `BookEditionShelf.withInheritedPublishers` — a row with no
     publisher takes the one every other row of its work states, when they
     agree. Not labelled on the shelf: the label would be part of the shelf's
     name, which is the group key, and split the run again.
   - (iv) left as is, as recommended.

The questions as they were put:

**1. Notifications that got put off — how long do they stay put off?**
- What: a reminder the app held back (quiet hours, too many at once) — should it still fire two weeks later?
- Two kinds: (a) "a new chapter came out" — stale news after 14 days; (b) "the volume you were waiting for is out" — never stale, you asked for it.
- Recommendation: drop (a) after 14 days, always deliver (b). One flag on `NotificationPolicy`, ~20 lines.
- Impact if wrong: either a pile of two-week-old chapter pings on a Monday, or a missed volume you were waiting on.
- Answer needed: "yes 14 days for chapters" or a different number.

**2. Tests that read the source files skip in Xcode Cloud.**
- What: 55 test files check things by reading the app's own source (e.g. "is this leg `.background`?"). Xcode Cloud's test phase has no checkout, so they skip silently there and only run on your Mac and in the pre-push hook.
- Options: (a) accept it — the hook already runs them before every push, the cloud is a second net; (b) copy the sources into the test bundle so the cloud runs them too (bigger test bundle, ~1 MB, and every new source file must be listed).
- Recommendation: (a), plus print the skip count in the cloud log so it's visible. Zero risk today because nothing reaches `main` without the hook.
- Answer needed: "a" or "b".

**3. Four wording/grouping calls on the Japanese volumes shelf** (all on real NDL data):
- (i) A not-yet-released volume with no ISBN can't be ticked as owned when its title is written differently from the catalogued one. Options: don't allow ticking unreleased rows / match on work title + volume number instead / accept. Recommendation: match on work + number (keeps the tick; one source only).
- (ii) Settings' "Erase N ticks" counts ticks for volumes that no longer appear. Options: word it "N ticks (some for volumes no longer listed)" / purge after a year. Recommendation: the wording; purging deletes something you did.
- (iii) A not-yet-released volume with no publisher sits on its own shelf beside the publisher's 1–17. Options: inherit the publisher from the sibling rows / leave. Recommendation: inherit — it's the same work on the same page; label it as inferred.
- (iv) Solo Leveling's side story shelf is named "…外伝　01" because NDL didn't mark the 01 as a volume. Options: strip a trailing number when no volume field / leave. Recommendation: leave — stripping would mangle titles that genuinely end in a number.
- Answer needed: four letters, or "all as recommended".


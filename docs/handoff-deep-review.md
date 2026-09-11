# Handoff — after the deep review, 2026-09-11

Written before compaction. Read this, then `docs/reviews/SUMMARY.md`, then work.

## The order Abdi set, in his words

1. **Fix it all** — every finding from both waves.
2. **The feel of the app** — `docs/feel-plan.md`. "Smooth transitions and animations.
   I want haptics. I want this app to win design awards and I want it to be addictive."
3. **Ship it all** — one push at the end. Then push `apple-idiomatic` too if it changed.

Standing rules unchanged: don't ask, build the best version and say so in the commit;
one finding per commit with evidence; `xcodebuild test` + `swiftlint --strict` before
every commit, and **read the build result, not just the grep** — a broken build got
past the gate once tonight; prove a fix by watching its test fail first; one push at the
end; no GitHub Actions; nothing published; API budget ≤20 uncached req/min, ≤10 on
search, full stop after any 429.

**Grep before you commit a fix.** The charter's headline pattern — a correct rule
applied n−1 times out of n — was reproduced by me, tonight, inside the fix for it:
fixed the credential guard in `SecurityTests`, missed its duplicate in `LibraryTests`.
When you fix an assertion, a setter, a modifier: grep for its siblings first.

## What the review is

`.claude/skills/deep-review/` — ported from MangaTranslator, charter rebuilt from this
project's own failures. **It is gitignored** (`.claude/` is in `.gitignore`); Abdi has not
said whether to track it. Ten agents ran: six slices, four for the directories the first
wave missed, one synthesis. **139 findings.** Reports in `docs/reviews/`:

- `SUMMARY.md` — read first. Ranked table of all wave-one findings, six cross-cutting
  causes, verdicts, contradictions, unknowns.
- `wire.md`, `persistence.md`, `reader.md`, `library-ui.md`, `discovery-ui.md`,
  `surface.md` — wave one.
- `auth-notifications.md`, `images-characters.md`, `remaining-screens.md`, `tests.md`
  — wave two. **Not in SUMMARY.md** — synthesis ran before they landed. Read them
  directly; their top findings are listed below.

## Fixed — 2026-09-11, 55 commits since the last push, 777 tests

Every finding in the "still to fix" list that stood here is done, one commit
each, test-fails-first where a test could see it. `git log 247eb91..HEAD`
is the record; each message carries the failure it was proved by. In outline:

- **Rate limit and network** — W6, R6 (via a shared `RequestSpacing`, three
  clients), D-A1, D-B1, D-A2, IC-F1 (pixel-based cover picker), IC-F4/F5,
  W9, R10, the taste profile's cache-on-failure, W7/W8 (one `perform()` path
  for reads and writes).
- **Failure as emptiness** — L1 (`LibraryModel.screenState`), R8 (schedule
  and reminders), R7, RS-1, W10, P-F9, W1-W4 (nullable wire fields), W13
  (endpoint list derived from source), W14, W5, W17, W11, W12.
- **Reminders** — R1 (nudges keep their date), A4 (trigger never in the
  past), R25 (local release day).
- **Statistics** — R12, R13, R19, R4 (card deleted: `ratingCount` is absent
  on v1, 0 hits in the recorded library), R18, R2, R9, R5 (`Cadence.gaps`),
  L9, L2, R16, R17, R14, R15, R20.
- **Computed and discarded** — stack `source` and `saveConfirmation`,
  `TasteModel` deleted, the library row's Edit (UI test), `popToRoot` wired.
- **Schedule** — RS-3, Browse header, R11, R21, R22/R23 (schedule reads the
  shared library walk).
- **Per body pass** — L4/L5 (measured: 0.86 ms a pass before, 9 µs after),
  D-B3, D-D1, B4 (models above the `.id`), E1 (watched on the simulator).
- **Surface** — S-F3, S-F2, S-F8, S-F15, IC-F3, S-F11 (measured: our launch
  path is 2-10 ms; F1 is a negative result), S-F18, S-F9, S-F13, S-F16,
  S-F20, S-F22, P-F11, P-F7/P-F8 (caches trimmed).
- **Tests** — three suites serialised, `mix.json` dated, eight assertions
  made to assert the thing (3.1-3.4), the secrets / identity / source-read
  guards closed (2.5-2.7), repository tests off the app's defaults.

Withdrawn as false positives, recorded in code so they are not re-proposed:
W15 (`preferredCover` nil means the series' own cover stands), P-F6, the
SKIP/SAVE contrast.

## Deliberately left, with reasons

- **Decisions for Abdi** — `ShelfDetailView` delete-or-rewire; L12 two rating
  scales (out of 5 in Library, out of 10 in Wrapped); L7 the A-Z jump index at
  20×13pt (a redesign); L11/S-F21 the hand-drawn switch (contested in the
  review itself); S-F12 `AppServices`' nineteen values.
- **Judgement calls** — R24 series titles on the lock screen; D-A3 tag chips
  re-blend and type chips do not; P-F10 a client backstop for `tag_not`.
- **Would need a measurement first** — S-F17 the gallery's two 1000pt blurs;
  S-F5 `heroTitleTravel` at AX sizes; S-F14 leading vs Dynamic Type; S-F19
  Bold Text; S-F6 `Motion` and view invalidation; S-F4 the key-window inset.
- **Tied to the shelf decision** — L3 `shelves` derived for a screen nothing
  presents.
- **Small and unglamorous** — L10 the 0.6/0.3 thresholds in a view (label
  them when next in the file); P-F12 three filter functions as one; D-A4;
  D-B2; W16 a comment naming values the schema lacks.

## Then: the feel pass

`docs/feel-plan.md`, in order: haptics → press feedback → numeric transitions → zoom
transitions everywhere → scroll transitions and snapping → symbol effects → shimmer.
Principle: motion explains, haptics confirm. Nothing bypasses `Motion.reduced`.

## Then: ship

`git push origin main`. Pre-push runs the full suite. Then update
`docs/overnight-2026-09-11.md` or write a sibling with what changed, and send Abdi the
three most useful screenshots.

## Corrections owed to Abdi, already made in chat, recorded here

- The OpenAPI spec was in the repo all along (`docs/schemas/`). I said it wasn't served.
- I claimed SKIP/SAVE badges failed contrast; they're at `opacity(0)` in a static audit.
- The wave-one slices missed ~3,050 lines and the whole test suite. Wave two fixed that.

## Where things are

- Simulator: iPhone 17 Pro `BF8CB720-DAC1-4656-B974-421F4A41C4C1`, app id
  `dev.abdirahmanmohamed.mangabaka`. Has Abdi's real 939-series library cached.
- Phone is unplugged. Nothing left needs it.
- Branch `apple-idiomatic` pushed; `docs/apple-experiment/` on it.
- 720 tests, 152 suites, all green at `fae9a29`.

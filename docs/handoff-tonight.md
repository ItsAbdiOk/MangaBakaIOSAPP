# Handoff — the overnight run, 2026-09-11

Written before compaction. This file is the plan; `docs/findings-todo.md` is the
list. Work through it in order, commit each item on its own, push once at the end.

## Standing rules for the night

- **Do not ask.** If a fix turns out bigger or riskier than the list implies,
  build the best version and say so plainly in the commit body so it can be
  reverted. Tests and git are the safety net. Never stop and wait.
- **Commit one finding per commit**, with its evidence in the message.
- **Before every commit**: `xcodebuild test -scheme MangaBaka` (641+ tests) and
  `swiftlint lint --strict`. Run `xcodegen generate` after adding any file.
- **One push at the very end.** Pushing triggers an Xcode Cloud build, so a
  single push, not one per commit.
- **Prove each fix.** Where a bug is being fixed, write the test first, watch it
  fail, then fix. Paste the failure into the commit body.
- No GitHub Actions, ever. No publishing, no TestFlight invite, no App Store
  submission.

## API rate limits — documented, from mangabaka.org/api

- `/series/search`: **30 requests per minute**, IP + leaky bucket.
- Everything else, `GET *` and `/my/*`: **180 per minute**.
- **Only UNCACHED requests count.** Repeating `GET /v1/series/1` costs one
  request, not ten. `cf-cache-status: HIT` in the response says it was free.
- Exceeding gives 429. The app already honours `Retry-After`.
- **Working rule for tonight**: at most 20 uncached requests a minute, at most
  10 a minute against search, and a full 60-second stop after any 429. The limit
  is per IP and shared with real users; a 429 is someone else's failed request
  too.
- **Use the API Explorer, not blind probing.** mangabaka.org/api links an
  OpenAPI 3.1 explorer. Read the spec to answer "does endpoint X exist" instead
  of firing requests at guessed paths — that is what burned the budget today.

## The order of work

### 1. Fix every finding in docs/findings-todo.md
34 items, groups A to H, already ordered. A (correctness) and B1 (the missing
scroll edge) first — B1 is the highest-leverage single fix in the app.

Decisions already taken, do not re-litigate:
- **Contrast**: raise per use, not wholesale. Keep the faint tiers for
  decorative marks; move informational text (provenance, credits, counts, card
  meta) to `textMuted` or higher.
- **Touch targets**: chips stay visually 30pt; extend the tappable area to 44pt
  with padding and `contentShape`. The mockup keeps its look.

### 2. The six unknowns (group H) — investigate, then fix
Do not defer them. An investigation that ends without an answer is recorded as a
negative result with its reason, per CLAUDE.md. Heavy lanes (a Periphery scan,
an on-device Instruments run) are approved for tonight; run one at a time.

### 3. Then build the parity features that need no design
From the website comparison:
- **Community pulse** (`/v0/frontpage/community-pulse`, live and unused).
  Abdi asked for "a cool way to display these" — it carries active series count,
  the previous week's count, and new-this-week. One honest, well-made surface,
  not a vanity dashboard.
- **All alternative titles** on a series page. The website offers "Show 36 more
  titles"; we decode every title already and show one.
- **Links grouped by purpose** — PUBLISHER / BUY / READ OFFICIALLY / INFO /
  SOCIAL, as the website groups them. `SeriesLink.type` is already decoded and
  unused.
- **Per-series Works** (volumes with release dates, prices, ISBNs) — CHECK THE
  EXPLORER FIRST for the endpoint; `/v1/works/upcoming` exists, a per-series
  form may not.
- **Custom lists** — the website tracks "lists" alongside status and notes.
  Check the explorer for the endpoints before building anything.

Explicitly NOT tonight: the moderator leaderboard (he does not care), the public
stats page and anything else needing design.

### 4. Then the Apple experiment
Build a version of the app as Apple would have it, so he can see and feel the
difference before deciding anything.

His reasoning, in his words: when iOS 26 shipped, apps using Apple's own nav bar
got Liquid Glass for free. He wants the version that inherits those upgrades
naturally. He is not committing to it — he wants to look at it and may then
compromise on his own design.

- Keep it separate and reversible: a branch, not main.
- Use the real components: `navigationTitle` with a genuine large-title bar and
  its scroll-edge effect, `List` with native sections, `Form` in Settings,
  `.searchable`, native swipe actions, standard `Section` headers, system
  materials, semantic colours that adapt, SF Symbols at their intended weights.
- Note where his mockup and Apple's pattern genuinely disagree, and what each
  costs. Several of tonight's findings exist BECAUSE the app hand-rolls what
  Apple provides — the missing scroll edge above all.
- Deliverable: screenshots from the simulator plus a build he can run, and a
  short honest note on what improved, what got worse, and what would be
  inherited free in future iOS releases.

## Waiting on Abdi — remind him

- **The public shareable stats page needs designing.** He wants to use Claude
  Design for it tomorrow. REMIND HIM.
- **Import from Tachimanga backups**, so the app can learn real reading speed
  rather than the current published-average guess (manhwa 6 min, novel 20,
  default 11 — labelled a guess in `ReadingInsights`). Needs the backup format
  investigating and probably a design. Not tonight.

## Where things are

- `docs/findings-todo.md` — the 34 items with evidence.
- `docs/ios-design-review-2026-09-10.md` — the full review: static audit, device
  pass, Apple's accessibility audit, device performance traces.
- `docs/accessibility-audit-2026-09-10.tsv` — the raw 86 issues.
- `.gstack/security-reports/` — the /cso report (gitignored).
- `docs/designs/api-opportunities.md` — the 2026-09-09 API exploration.
- Accessibility audit runs as `xcodebuild test -scheme MangaBakaAccessibility`.
- Performance suite runs as `xcodebuild test -scheme MangaBakaPerformance`.
- Simulator: iPhone 17 Pro `BF8CB720-DAC1-4656-B974-421F4A41C4C1`.
- His iPhone 16 Pro for xctrace: `00008140-0005191901A2801C` (devicectl uses a
  different id: `B9F6AD54-91D4-5D1E-BAD9-E0D99A500477`).

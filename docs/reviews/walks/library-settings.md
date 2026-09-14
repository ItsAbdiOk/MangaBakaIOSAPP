# Walk: Library tab and Settings

Device: iPhone 16 Pro simulator, `dev.abdirahmanmohamed.mangabaka`, today's build. Read-only walk — no build, no source edits, no destructive taps. Screenshots referenced below live alongside this report's session scratchpad and are not committed; filenames are cited for traceability within this walk only.

## The header/body contradiction — reproduced and resolved

Reproduced immediately on cold open of the Library tab: the header reads **"945 series · 429 dropped · 425 rated"** while the body directly beneath it reads **"No library yet — Add a MangaBaka token in Settings and everything you track there appears here."** (screenshot `06-library-attempt.png`, both in one frame).

Waited 2 seconds and re-screenshotted (`07-library-after-2s.png`): identical. This is not a transient loading state — it is a steady-state, persistent contradiction.

**Which one is telling the truth:** the body. I opened Settings → Account and it plainly reads **"No account"** with an empty token field (screenshot `08-settings.png`). There is no MangaBaka token configured on this install. So "No library yet" is correct, and the header's "945 series · 429 dropped · 425 rated" is wrong — it should read 0.

**Root cause (observed, not guessed):** further down in Settings, under Data Used, there is a "Taste profile" row reading **"945 series counted · 3175 tags known"** (screenshot `11-settings-scroll2.png`). The 945 figure in the Library header exactly matches this taste-profile count, not anything from a live library fetch (which can't exist — there's no token to fetch with). This strongly suggests the Library header is reading a cached/leftover aggregate count (from the taste-profile computation, presumably left over from a prior session or account state) rather than checking whether a library actually exists. The body's empty-state correctly checks for token presence; the header does not, or reads a different, stale source. The 429 dropped / 425 rated figures were not independently traceable to a visible settings value in this walk, but given the exact match on 945 they most plausibly come from that same stale cached snapshot rather than a live count of zero.

**Impact:** this is a real, user-visible trust bug — someone with no account configured is told they have a library of 945 series and then immediately told they have no library at all. Contradicts within a single screen with no explanation.

## 1. Cold open of Library

No partial-load state, no "Showing the first N" banner, no spinner observed. The screen renders instantly straight to the stats-header + empty-state combination described above. Nothing to "clear when the walk finishes" because nothing ever loaded — consistent with no token being configured.

## 2–6. Scroll, filter chips, sort, jump index, edit sheet, Insights/Wrapped

**Not testable in this account state.** With no token, the library body is genuinely empty (per Settings → Account → "No account"), so there is no list of ~945 entries to scroll, no filter chips, no sort control, and no jump index rendered anywhere on the Library screen (screenshots `14.png`, `15-tap-stats.png`). Tapping the stats line itself does nothing (not a link into Insights/Wrapped). I did not find a route into Insights or Wrapped from this empty Library screen — there is no visible entry point for them when the body is in the empty state. This walk cannot confirm or deny bugs in those areas; they need a fixture with an actual token/library to exercise. Flagging as a gap rather than guessing.

## 7. Settings — load timing and export/import

Settings opens without a visible loading delay. Scrolling through Account, Series Titles, Formats, Content, Blocked Tags, Release Reminders, Recently Viewed, Library Backup, Data Used, and Translation sections, nothing showed a spinner or lazy pop-in.

Library Backup section (Export as JSON / Export as CSV / Import…) sits statically with no evidence of eager work — no counts, no progress, no computation visible before tapping (screenshot `11-settings-scroll2.png`). I did not tap Export or Import since doing so would perform the actual action; the observation here is limited to "nothing fires just from scrolling the section into view," which is what was asked. Given there's no library, an actual export attempt would be a good separate test once a token is present.

One good, worth calling out: **Data Used** section states "Counted on this phone and never sent anywhere. It resets when the app closes" and shows "This session: 133 requests · 10.8 MB of it cover art" plus "Taste profile: 945 series counted · 3175 tags known." Transparent, specific, and honestly scoped — this is the best copy in the section and possibly the app.

## 8. Release reminders caption

Exact text observed (screenshot `12-reminders.png`):

> "A confirmed release, once the app has seen it — which is next time you open that series. Plus word when a series you're reading or have paused has completed or ended a season. Nothing else."

The toggle below it, "Release notifications," is off, captioned "Nothing leaves this phone. iOS schedules these locally." Did not toggle it (would enable notifications, an out-of-scope action per the walk rules). The promise, precisely: a notification fires only (a) the next time you open a series after a release the app has already detected, and (b) once, when a series you're reading or have paused completes or a season ends. Explicitly "nothing else."

## Other observations

- Recently Viewed section shows "Clear 11 series" — so 11 series exist in local recently-viewed history despite "No library yet" and "No account." This is a separate, legitimately independent local cache (per its own caption: "stored on this phone... clearing it does not touch your library") — not a contradiction, just worth knowing it survives account state.
- The bottom tab bar intermittently collapses to a two-icon floating cluster (just the active tab + search) instead of showing all four tabs + search, observed after navigating between Search and Library (compare `00-initial.png`'s full 5-icon bar vs. `14.png`'s 2-icon bar). Did not fully diagnose the trigger — plausibly tied to scroll position or a transition — but it is a real, observed layout change, not a one-off screenshot artifact, since it recurred across multiple screens after the same navigation pattern.

## Gaps / what's unverified

- Everything requiring an actual populated library (items 2–6) is unverified. This account has no token, so the "~945 entries" mentioned in the task brief could not be scrolled, filtered, sorted, or jumped through, and no row existed to open an edit sheet on. Needs a re-run with a token configured.
- Did not tap Export/Import/Block a tag/Save-token to avoid side effects beyond the walk's scope.
- Budget used: ~40 of 70 tool calls (screenshots + taps), left unused headroom rather than guessing at untestable areas.

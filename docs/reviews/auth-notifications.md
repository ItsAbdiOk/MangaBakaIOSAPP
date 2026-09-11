# Slice review — Core/Auth + Core/Notifications + Core/Telemetry + Core/History

Read-only review, 2026-09-11. No build, no test run, no edits outside this file.

## Denominator

The slice is **6 files, 569 lines, all read in full**:

- `MangaBaka/Core/Auth/TokenStore.swift` (96)
- `MangaBaka/Core/Auth/Profile.swift` (18)
- `MangaBaka/Core/Notifications/ReleaseReminders.swift` (223)
- `MangaBaka/Core/Telemetry/NetworkLedger.swift` (84)
- `MangaBaka/Core/Telemetry/Signposts.swift` (42)
- `MangaBaka/Core/History/HistoryStore.swift` (106)

Read outside the slice, because a claim about the token path or the reminder
path cannot be grounded inside it:

- `Core/Networking/TokenProvider.swift` (full), `Core/Networking/APIClient.swift`
  (lines 100–300 only — the request-building, ledger and mutate paths)
- `Features/Settings/SettingsView.swift` (full), `Features/Settings/AccountCard.swift`
  (lines 150–215), `App/RootView+Session.swift` (lines 75–150)
- `Configs/Base.xcconfig`, `Debug.xcconfig`, `Release.xcconfig`,
  `Secrets.example.xcconfig`, `Secrets.xcconfig`, `Info.plist`,
  `MangaBaka/Resources/PrivacyInfo.xcprivacy`, `.swiftlint.yml`, `.gitignore`,
  `MangaBaka.xcodeproj/project.pbxproj` (xcconfig wiring lines only),
  `Package.resolved`
- `MangaBakaTests/ReminderTests.swift` (full)

**Not read, and therefore not reviewed:** `APIClient.swift` lines 1–99 and
300–end; `App/RootView.swift`; the bodies of `MangaBakaTests/HistoryTests.swift`
(test names only); `Features/Settings/RemindersSection.swift` and
`HistorySection.swift` beyond the greps quoted below; `Features/Discovery/RecentlyViewedRow.swift`
beyond its two `history` call sites.

11 findings. Nothing here re-reports an item closed in `docs/findings-todo.md`
or `docs/unknowns-2026-09-11.md`, and the already-found
`ReleaseReminders`-relative-dates issue (`docs/reviews/reader.md` R1) is not
repeated — A4 below is a different mechanism in the same file.

---

## Question 1 — the token. Answered first, as instructed.

**Verdict: the storage and the build-time claims all hold. The gap is not in
how the token is kept, it is in what happens when it is removed (A1).**

Each claim in the brief, checked against code rather than assumed:

| Claim | Verified at | Holds? |
| --- | --- | --- |
| Never hard-coded; lint enforces it | `.swiftlint.yml` `no_hardcoded_token`, regex `"mb-[A-Za-z0-9]{8,}"`, `severity: error`, tests excluded | Yes, with a hole — see B7 |
| `Secrets.xcconfig` gitignored | `.gitignore` `Configs/Secrets.xcconfig`; `git ls-files Configs/` lists only the `.example` | Yes |
| Its value never printed | no `print(`, no `Logger(`, no `os_log` anywhere in `MangaBaka/` (grep); the only logging is `Signposts.swift:17`, which takes `StaticString` names only | Yes |
| A Release build carries no token | `Configs/Base.xcconfig` omits it; `Debug.xcconfig:8` `#include? "Secrets.xcconfig"`; `Release.xcconfig:9` `MB_PAT =` forces it empty; `project.pbxproj:1598` wires `Release.xcconfig` to the Release configuration and `:1706` wires `Debug.xcconfig` to Debug | Yes — three independent layers |

Where the token can and cannot go:

- **Header only, never a URL.** `TokenProvider.swift:41` returns
  `("x-api-key", token)`; it is applied with `setValue(_:forHTTPHeaderField:)`
  at `APIClient.swift:126` and `:243`. `makeRequest` builds the URL from
  `path` + `query` and never sees the token.
- **Not in the ledger.** `APIClient.swift:145` records `path:` only — no query
  string, no headers — and `NetworkLedger.shape` (`NetworkLedger.swift:73`)
  strips ids on top of that. A reader's search terms never enter the tally
  either.
- **Not in an error message.** The two `String(describing: error)` sites
  (`APIClient.swift:253`, `:295`) describe a `URLError` or a decoding error.
  A `URLError`'s userInfo carries the failing **URL**, which has no token in
  it; the decoding one describes the response body.
- **Not on screen.** `AccountCard.swift:188` is a `SecureField`, with
  `.autocorrectionDisabled()` (`:191`) and
  `.textInputAutocapitalization(.never)` (`:190`) — so the token is not
  learned by the keyboard. The connected state prints twelve bullets
  (`AccountCard.swift:166`), never the value.
- **Not in a crash report.** No `fatalError`, no force-unwrap, no `try!` on
  any path that holds the token; `force_unwrapping`, `force_cast` and
  `force_try` are all `severity: error` in `.swiftlint.yml`.

Keychain attributes are right and the reasons are recorded:
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` at `TokenStore.swift:48`,
with `TokenStore.swift:6-12` explaining both halves.

---

## Tier 1 — a real failure, with the input that triggers it

### A1. "Remove token" signs the reader out without forgetting the previous account

- **What** — the Save path calls `onAccountChanged()`; the Remove path does
  not, so removing a token clears the Keychain and leaves the previous
  account's taste ledger, cached profile id and library snapshot on disk.
- **Where** — `MangaBaka/Features/Settings/SettingsView.swift:64-68`
  (`onRemove: { store.clear(); storedTokenExists = false; entry = ""; status = .idle }`)
  against `:150` and `:160`, which both `await onAccountChanged()`. The handler
  it skips is `MangaBaka/App/RootView+Session.swift:100-104`
  (`library.forgetProfile()`, `taste.forgetEverything()`,
  `librarySnapshot.invalidate()`).
- **Why it matters** — this is the exact bug the charter records under pattern 3
  and that `RootView+Session.swift:93-99` was written to close, surviving in the
  one path nobody wired. Input: tap **Remove token**, then paste a different
  account's token. Save → `save()` → `onAccountChanged()` runs, so that route is
  safe. But a reader who removes first and enters later gets recommendations
  built from the previous person's reading in the window between, and
  `SettingsView.swift:20` states the principle it violates — *"A token is a
  person, not a setting."*
- **Effort** — a line, plus making `onRemove` async so it can await. `onRemove`
  is currently a synchronous closure (`AccountCard.swift:180`), so the signature
  has to change.
- **Confidence** — certain.

### A2. Nothing clears the reading history when the account changes

- **What** — `forgetPreviousAccount()` forgets the library profile, the taste
  ledger and the snapshot, and does not touch `HistoryStore`, so the next
  person's Discover screen opens with a "Recently viewed" row belonging to the
  previous one.
- **Where** — `MangaBaka/App/RootView+Session.swift:100-104` (no `history`
  reference anywhere in the function); `MangaBaka/Core/History/HistoryStore.swift:84`
  `clear()` has exactly one caller,
  `MangaBaka/Features/Settings/HistorySection.swift:51`, which is the manual
  Settings tap.
- **Why it matters** — this is a reading-history log, and `HistoryStore.swift:10-13`
  says so plainly: *"This is a reading-history log, and it is treated as one."*
  Twenty series with covers and titles is the most personally identifying thing
  the app holds. A token change is a change of person, and the whole of
  `forgetPreviousAccount` exists on that premise; the history was left out of it.
  Input: enter account B's token on a phone where account A had browsed.
- **Effort** — a line (`try? await history.clear()` inside
  `forgetPreviousAccount`) — but it is a product call first. A reasonable
  counter-argument exists: history is device-scoped, not account-scoped, and
  someone handing their own phone between two of their own tokens may not want
  it wiped. Bring it to Abdi rather than just adding the line.
- **Confidence** — certain on the mechanism; the *should it* is the open part.

### A3. Reminders naming the previous account's series stay pending after a token change

- **What** — `forgetPreviousAccount()` does not reschedule, and reminders are
  only rebuilt on foreground or on the switch moving — so pending notifications
  built from the old library survive the sign-out.
- **Where** — `MangaBaka/App/RootView+Session.swift:100-104` (no
  `refreshReminders()` call) against `:118` (`startSession`) and `:127-145`
  (`refreshReminders`), the only two things that drive
  `ReleaseReminders.reschedule` (`Core/Notifications/ReleaseReminders.swift:76`).
- **Why it matters** — the catch-up bodies carry library content by name:
  `ReleaseReminders.swift:141` `"\(title) has finished"` and `:157`
  `"\(biggest.waiting) chapters of \(title) are waiting"`. Input: remove the
  token in Settings, background the app, do not reopen it. At 09:00 the phone's
  lock screen names a series from an account the reader has signed out of. It
  self-corrects on the next foreground (`removeAll()` at `:81`), which is why
  this is a window rather than a permanent state — but the window is as long as
  the reader stays out of the app.
- **Effort** — a line: `await refreshReminders()` at the end of
  `forgetPreviousAccount`, which will hit the `guard reminders.isEnabled` /
  empty-library path and clear them.
- **Confidence** — certain on the mechanism; the size of the window depends on
  how much of the announced list was already scheduled.

### A4. A release due later today is scheduled for 09:00 today — a trigger already in the past — and never fires

- **What** — the guard admits any date later than *now*, and the trigger then
  pins the hour to 9. For a date falling today after 09:00, the resulting
  `UNCalendarNotificationTrigger` describes a moment that has passed, and a
  non-repeating calendar trigger whose components are in the past does not fire.
- **Where** — guard at
  `MangaBaka/Core/Notifications/ReleaseReminders.swift:87`
  (`guard let date = work.date, date > Date()`) and `:98`
  (`cadence.due > Date()`), against
  `MangaBaka/Core/Notifications/ReleaseReminders.swift:209-214`:
  ```swift
  var components = Calendar.current.dateComponents([.year, .month, .day], from: request.date)
  components.hour = 9
  let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
  ```
  The `try?` at `:215` means even an outright `add` rejection is silent.
- **Why it matters** — "out today" (`:92`) is the one notification in the file
  that states a fact rather than an estimate, and it is the one most likely to
  be about today. Input: the reader opens the app at 10:00 and a series in their
  library has a release dated today. It is admitted by the guard, converted to
  09:00 today, and dropped. The failure is invisible in both directions: the
  reader assumes nothing was due, and the app has no record it failed.
  Charter pattern 5, one layer down — the guard measures "is the date in the
  future", the thing that matters is "is the *trigger* in the future".
- **Effort** — a line in `LiveNotificationCentre.add` (if the composed 09:00 is
  already past, fire at the next sensible minute instead), or move the 09:00
  decision up into `reschedule` where the guard lives, which is the better shape
  because it makes the guard and the fire time the same number.
- **Confidence** — certain that the trigger is composed in the past; **likely**
  on iOS silently dropping it. I have not run it, and I would rather say so than
  assert Apple's exact behaviour from memory. Worth a one-off device check
  before the fix is designed — but the mismatch between `:87` and `:211` is a
  defect either way, because nothing in the code makes the two agree.

---

## Tier 2 — real, smaller, or contingent

### B1. The notification test seam stops one layer above the code that has the bug

- **What** — `FakeCentre` conforms to `NotificationScheduling`, so every test
  asserts on `ReminderRequest` values. `LiveNotificationCentre` — the 09:00
  conversion, the trigger construction, the `try?` that swallows an add failure,
  the alert/sound options — has zero coverage.
- **Where** — `MangaBakaTests/ReminderTests.swift:108-122` (`FakeCentre`)
  against `MangaBaka/Core/Notifications/ReleaseReminders.swift:188-222`.
  `skipsThePast` (`ReminderTests.swift:67-78`) is the clearest case: it proves
  the `date > Date()` guard, which is precisely the check A4 shows is the wrong
  one, and it passes.
- **Why it matters** — charter pattern 2. Six tests pass, the file reads as
  tested, and the untested third of it is where both A4 and the already-found
  R1 live. The seam is well designed for what it tests; the problem is that
  nothing states it is a *partial* seam, so the coverage reads as complete.
- **Effort** — a function: make the calendar components a pure static on
  `ReleaseReminders` (`fireDate(for:)`) that `LiveNotificationCentre` calls, so
  the rule can be tested without a notification centre. That also fixes A4's
  shape.
- **Confidence** — certain.

### B2. `HistoryStore.entries` discards a row whose payload no longer decodes, silently

- **What** — `compactMap { try? decoder.decode(Series.self, from: $0.payload) }`.
  A row written by an older build of `Series` that no longer decodes is dropped
  with no signal, no migration and no count.
- **Where** — `MangaBaka/Core/History/HistoryStore.swift:72`.
- **Why it matters** — charter pattern 1, in its "a decode failure and an empty
  result are indistinguishable to the caller" form. `Series` has been reshaped
  repeatedly in this project (the charter lists four payload-model
  disagreements). Input: any release that changes `Series`' stored shape — the
  reader's Recently viewed row goes empty on upgrade, the Settings count
  (`HistoryStore.swift:92`, which uses `fetchCount` and so still counts the
  undecodable rows) says 20, and the two disagree with nothing explaining why.
  The caller compounds it: `Features/Discovery/RecentlyViewedRow.swift:30`
  wraps the whole thing in another `try?` with `?? []`.
- **Effort** — a function. Either version the payload, or have `entries` return
  the undecodable count so `count()` and the row can agree, or delete
  undecodable rows on read so the two converge.
- **Confidence** — likely. It needs a `Series` change to bite, and I did not
  read `Series.swift` to check how close the current shape is to breaking.

### B3. A Keychain save failure is reported with the status code thrown away

- **What** — `write` collapses every `OSStatus` to `false`, so Settings can only
  say "Could not save to the Keychain" with nothing behind it.
- **Where** — `MangaBaka/Core/Auth/TokenStore.swift:51-57` (the status is
  compared and discarded; `SecItemAdd`'s status likewise at `:54`) surfacing at
  `MangaBaka/Features/Settings/SettingsView.swift:142-144`.
- **Why it matters** — this is the one failure in the token path a reader
  cannot work around and cannot report usefully. `errSecInteractionNotAllowed`
  (device not unlocked since boot, which `afterFirstUnlock` makes reachable),
  `errSecAuthFailed` and a missing-entitlement `errSecMissingEntitlement` are
  three completely different problems presented identically. `.swiftlint.yml`'s
  `no_catch_all_error_handling` rule exists for exactly this shape and does not
  match it, because this is not a `catch` block.
- **Effort** — a line: return the `OSStatus` (or a small enum) instead of
  `Bool`, and include it in the message.
- **Confidence** — certain.

### B4. The full token stays in memory and on screen after MangaBaka rejects it

- **What** — `entry` is cleared only on `.accepted`. After `.rejected` the
  `SecureField` still holds the complete PAT, and `save()` has by then already
  deleted it from the Keychain.
- **Where** — `MangaBaka/Features/Settings/SettingsView.swift:169`
  (`entry = ""` inside `case let .accepted`) against `:170-171` (`.rejected`)
  and `:176` (`.unverified`); the field is `@State private var entry = ""` at
  `:24`, bound at `AccountCard.swift:188`.
- **Why it matters** — small, and partly deliberate: the button relabels to
  "Paste a new one" (`AccountCard.swift:205`), so keeping the field populated is
  arguably the kinder behaviour for a typo. But a rejected credential is still a
  credential, it now lives in a `@State` `String` for as long as the screen
  exists, and it is the value most likely to be a *correct token for a different
  service*. Worth a deliberate decision rather than an accident of which switch
  case got the line.
- **Effort** — a line, if the decision is to clear it.
- **Confidence** — certain on the behaviour; the severity is a judgement call,
  and I would put it to Abdi rather than assert it.

### B5. The Keychain is read synchronously on the main thread in a SwiftUI `@State` initialiser

- **What** — `@State private var storedTokenExists = TokenStore().read() != nil`
  runs `SecItemCopyMatching` during view-struct construction, which SwiftUI does
  on every re-evaluation of the parent.
- **Where** — `MangaBaka/Features/Settings/SettingsView.swift:26`.
- **Why it matters** — `@State`'s initial value is only *used* on first
  construction, but the expression is *evaluated* every time the struct is
  built, so this is a main-thread Keychain call per parent re-render, not once.
  It is fast and will not be visible to a reader — the practical impact is
  small — but it is the kind of thing a hitch trace blames something else for
  later. Charter pattern 6's neighbourhood: state that belongs in a model living
  in a view.
- **Effort** — a line: move it into `.task` alongside the existing
  `check()` at `:53`, or hang it off the model that already owns `store`.
- **Confidence** — certain on the mechanism; **worth checking** on whether it is
  measurable. I did not measure it, and per CLAUDE.md a fix with no
  before-number is not a result — so this should be measured before it is
  "fixed".

### B6. `HistoryStore` performs its reads through the writer connection

- **What** — both read paths use `database.writer.read` rather than a reader,
  so they serialise against writes on GRDB's writer queue.
- **Where** — `MangaBaka/Core/History/HistoryStore.swift:66` and `:92`.
- **Why it matters** — with `limit = 20` rows this is genuinely not a
  performance problem today, and I am not claiming it is. It matters as a
  consistency point: if `AppDatabase` exposes a reader pool that other stores
  use, this one differs for no stated reason, and the difference will be copied.
  I did not read `AppDatabase`, so I cannot say whether a reader is even
  available — **worth checking**, not a defect claim.
- **Effort** — a line, if a reader exists.
- **Confidence** — worth checking.

### B7. The hard-coded-token lint matches only the alphanumeric shape, and the real token may not be one

- **What** — `no_hardcoded_token`'s regex is `"mb-[A-Za-z0-9]{8,}"`. A PAT
  containing an underscore, a hyphen or a dot after the `mb-` prefix would still
  be caught (the first 8 chars would have to be alphanumeric), but a token of the
  form `mb-` followed by a short segment and a separator — e.g.
  `"mb-live_abc123def456"` — is not matched, because `live_abc` breaks at the
  underscore after only 4 alphanumerics.
- **Where** — `.swiftlint.yml`, `custom_rules.no_hardcoded_token.regex`.
- **Why it matters** — the rule is the last line of defence behind
  `Secrets.xcconfig`, and its coverage depends on a fact about MangaBaka's token
  format that is not recorded anywhere. `TokenStore.looksValid`
  (`Core/Auth/TokenStore.swift:74-77`) makes a weaker claim — prefix `mb-` and
  length > 12 — so the two disagree about what a token looks like, and neither
  cites a source.
- **Effort** — a line: `"mb-[\w.\-]{8,}"`, and a comment recording where the
  format claim came from.
- **Confidence** — worth checking. I do not have a real token's format in front
  of me and am not going to look at the one in `Configs/Secrets.xcconfig` to find
  out. Flagging the *disagreement between the two rules*, which is real and
  checkable, rather than asserting the lint is broken.

---

## Question 3 — telemetry. Nothing leaves the device; the manifest holds.

Verified rather than assumed:

- `NetworkLedger` is an `actor` with three stored properties
  (`NetworkLedger.swift:30-32`), no `URLSession`, no file handle, no
  `UserDefaults`. It is never persisted and never serialised. Its only readers
  are `Features/Settings/DataUseSection.swift:126-129` — the Settings screen
  itself.
- Its two writers are `APIClient.swift:145` (path, bytes, seconds, failed) and
  `Core/Images/CoverStore.swift:125` (bytes). Neither passes a query string,
  a header, a series title or an identifier.
- `Signposts.swift:31-41` takes `StaticString` names only — by the API's
  requirement, so reader data *cannot* be interpolated into a signpost name even
  by mistake. The subsystem is the app's own bundle id (`:18`).
- One third-party dependency exists: GRDB 7.11.1 (`Package.resolved`). No
  analytics SDK, no crash reporter, no network library.
- `MangaBaka/Resources/PrivacyInfo.xcprivacy` declares
  `NSPrivacyCollectedDataTypes` empty, `NSPrivacyTracking` false,
  `NSPrivacyTrackingDomains` empty, and one required-reason API
  (`UserDefaults`, `CA92.1`) with a dated audit note. I found nothing in this
  slice that contradicts it.

One caveat, stated as a caveat: the manifest covers this app's source. Apple's
ITMS-91053 check runs on the **binary**, which includes GRDB. GRDB is not on
Apple's "commonly used SDK" list and so is not required to ship its own
manifest, meaning any required-reason API it uses (file timestamps are the
plausible one for a SQLite wrapper) would have to be declared by *this* app.
The manifest comment says file timestamps "were each searched for and are not
used" — which is true of the app's source and cannot be true of a search that
did not cover the dependency. **Worth checking** before the first upload; it is
a submission-time failure, not a runtime one, and it is a question for Abdi's
distribution decision (still open per `CLAUDE.md`), not a code change.

---

## Question 2 — notifications, answered directly

- **Scheduled:** four kinds. `announced-<work.id>` for a dated release
  (`ReleaseReminders.swift:88-94`), `predicted-<series.id>` for a cadence
  estimate (`:99-107`), up to three `finished-<seriesId>` (`:138-148`), and one
  fixed-id `catch-up` (`:155-162`). No id collisions: the four prefixes are
  distinct and the fixed one is a singleton.
- **When:** rebuilt wholesale on foreground and when the switch moves
  (`RootView+Session.swift:118`, `:127`). Fired at 09:00 local on the target day
  (`ReleaseReminders.swift:211`) — see A4.
- **Removed by:** `removeAll()` at the top of every `reschedule`
  (`:81`) and in `disable()` (`:67`). Nothing removes an individual id, which is
  the right call given the replace-wholesale design and the reasoning at
  `:71-75`.
- **Authorisation:** requested only inside `enable()` (`:52`), which is only
  reached from the Settings row (`Features/Settings/RemindersSection.swift:71`).
  Never at launch. A refusal turns the stored flag back off (`:55-57`) and
  returns false so the switch stays off — tested at `ReminderTests.swift:37-46`.
- **Revoked later:** `systemStatus` is refreshed on the section appearing
  (`RemindersSection.swift:54`) and drives a `.denied` hint at
  `RemindersSection.swift:38`. This is genuinely handled — it is not a
  computed-and-discarded.
- **After sign-out / after removing a series:** yes, within a window — A3.
  Both self-correct on the next foreground, and neither corrects before then.

---

## What this slice does well

Held to the same evidence standard.

- **The Release-build token exclusion is defended three times over, not once.**
  `Base.xcconfig:3-6` states the rule, `Debug.xcconfig:7-8` scopes the include,
  and `Release.xcconfig:8-9` sets `MB_PAT =` explicitly — with the comment
  saying why the belt was not enough: *"Xcode Cloud has no Secrets.xcconfig at
  all, but relying on that alone meant a hand-made local archive would have
  shipped a real credential."* That is a recorded near-miss, and
  `project.pbxproj:1598` confirms the Release configuration actually points at
  the file that carries the override. This is the strongest thing in the slice.
- **`TokenCheck` is three-valued and says why.** `TokenStore.swift:80-95`
  records the incident that produced the third case: a network failure reported
  as a rejection, which then deleted a working credential. The distinction is
  honoured downstream — `SettingsView.swift:152-161` clears the Keychain only
  on `.failed`, and `:172-176` explains the `unverified` path. A credential
  deleted by a dropped connection is a hard bug to diagnose after the fact, and
  this closes it structurally rather than by care.
- **The Keychain attributes carry their reasoning.** `TokenStore.swift:6-12`
  gives a separate justification for `afterFirstUnlock` (background refresh) and
  for `ThisDeviceOnly` (*"a token that syncs is a token that leaks somewhere its
  owner did not expect"*). Most code picks one of these constants by copying.
- **The app has no logger at all, which is why the token cannot reach a log.**
  Grepping `MangaBaka/` for `print(`, `Logger(` and `os_log` returns nothing
  outside `Signposts.swift`. The `no_print_statements` lint rule
  (`.swiftlint.yml`, severity error) keeps it that way. This is the rare case
  where a missing feature is the security control.
- **`NetworkLedger` was designed against the privacy risk, not retrofitted.**
  `NetworkLedger.swift:11-13`: *"Kept as a running tally rather than a log of
  every request: a log is a record of what someone read."* The `shape` function
  (`:73-83`) exists so the tally cannot become per-series, which is the same
  decision enforced a second way.
- **History filters content rating on read rather than on write, with the
  incident recorded.** `HistoryStore.swift:58-64` names the earlier bug —
  cached feeds showing exactly what a reader had just excluded — as the reason.
  That is a measurement-with-its-method comment of the kind CLAUDE.md asks for,
  and it is why `filtersByContentRating` in `HistoryTests.swift` exists.
- **The notification copy distinguishes fact from estimate on the lock screen.**
  `ReleaseReminders.swift:102-105`: *"A notification that states a guess as a
  fact is worse than no notification: it is the app being confidently wrong on
  the reader's lock screen."* The announced body says "out today"; the predicted
  one says "roughly due, going by how often it updates". Two different sentences
  for two different epistemic states is not a thing most apps bother with.
- **Badges were declined with a reason.** `ReleaseReminders.swift:194-195`:
  *"a number on the icon that nobody clears is a permanent accusation, and this
  app has nothing to count."* A recorded negative decision, per CLAUDE.md.
- **The 40-notification cap is labelled a guess.** `ReleaseReminders.swift:28-31`
  says the iOS limit is 64 and that 40 is *"picked rather than discovered"*.
  That is exactly what charter pattern 4 asks for, and it is worth naming
  because several constants elsewhere in the project were not labelled.

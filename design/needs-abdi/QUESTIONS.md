# Questions that need Abdi

Written 2026-09-10. Each one is blocking something, or will be before TestFlight.
Nothing here is a preference poll — these are decisions I should not make alone.

---

## 1. Does MangaBaka permit a public third-party client?

**Why it needs you:** the app ships to the App Store. That reverses the rule from
the last project. Right now the app calls four APIs and I have read the terms of
none of them:

| API | What it gives us | Status |
|---|---|---|
| MangaBaka v1/v2 | Everything — the app is unusable without it | No terms read, no key, no contact made |
| MangaUpdates | Release cadence, next-chapter prediction | 3s self-imposed spacing, no key |
| Shikimori | Characters (fallback) | Requires a User-Agent identifying the app; we send one |
| AniList | Characters (preferred) | **HTTP 403 — they have disabled the public API** |

**What I need:** have you spoken to MangaBaka, or should I draft the email? They
may want attribution, a User-Agent, a rate ceiling, or a key. Shipping a client
built entirely on someone's unmetered public endpoints without asking is the one
part of this project I would not defend.

Related: `blend_user_id` on the mix endpoint takes *another user's* id and blends
their taste into yours. Their docs do not say whose data that is or whether they
agreed. **I have not touched it and will not without you asking them.**

---

## 2. Attribution — does MangaBaka's data need visible credit in the app?

Settings has an attribution row with nothing settled in it. If they want a logo
or a specific string, that is a design constraint, not a footer I can invent.

---

## 3. Crash reporting on TestFlight — yes or no?

**Why it needs you:** you had me strip Google Analytics from the last project the
moment you learned it reported to someone else's account, so my default here is
zero telemetry, and that is what is built.

But on TestFlight with no crash reporting, a tester's crash reaches you as
"it closed" and nothing else. Apple's own **Xcode Organizer crash reports** are
opt-in per tester, go to your account only, no third party, no SDK, and no code
change. That is the one option I would take.

**Options:** (a) Apple's built-in only — recommended; (b) genuinely nothing;
(c) a third-party SDK — I would push back on this.

---

## 4. AniList is dead. Keep the code or cut it?

AniList returns 403 to everything, with their own message saying the public API
is disabled. The characters feature therefore runs on Shikimori 100% of the time
today, silently, which is what you asked for.

**The honest part:** the AniList path is written from their published schema and
has **never been run against a live response.** It could be wrong in ways no test
can catch. If they come back, the first real user is the person who finds out.

**Options:** (a) keep it, flagged as unverified — recommended, it costs nothing
while dead; (b) delete it and be a Shikimori client; (c) I find someone with a
cached AniList response to validate the decoder against.

---

## 5. "Recently viewed" — is local history acceptable?

MangaBaka has no such endpoint; their homepage's "Recently Added" is the same
data as New releases, which we already show. A genuine "recently viewed" means
**storing on the phone every series you open.** Small, never leaves the device,
never sent anywhere — but it is a reading-history log, and I am not adding one
without you saying so.

**Options:** (a) build it, last 20, clearable from Settings; (b) don't.

---

## 6. The app icon

Still the off-brand purple placeholder. You said leave it, and that was fine
while nothing shipped. TestFlight puts it on your testers' home screens.

**Options:** (a) I design one from the accent and wordmark; (b) you do;
(c) ship the placeholder to TestFlight and fix before the App Store.

---

## 7. Settings toggles: keep the drawn switch?

The real SwiftUI `Toggle` only ever responded to a drag, never a tap, verified
repeatedly on device. The workaround is a Button wrapping a drawn switch.

This is the weakest of the four deviations I am keeping — a workaround for
behaviour I never fully explained. If Settings gets a design, that is the moment
to try the real control again. Worth one more hour, or leave it?

---

## 8. Three features whose UI is missing, and I need to know if you want them

The data layer exists for all three. Only the screen is absent.

- **Mix → Tags and Blocked tags filters.** The API supports both, `SearchQuery`
  already carries tags. Purely a missing UI.
- **Mix → "Save as a lens".** Lenses ship as presets; writing your own needs a
  design (naming, editing, deleting, where they live).
- **Library → search field.** Once a library passes ~200 entries, scrolling is
  the only way to find anything.

Which of these are real, and which were mockup furniture?

---

## 9. Who designs the undesigned screens?

Six screens are engineering constructions wearing the mockup's colours — full
briefs in `design-prompts/`. You said yesterday you might "make it Claude design
tmr". Do you want to run those prompts, or should I build first drafts and let
you correct them?

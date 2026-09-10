# Settings

**Status:** 316 lines of working SwiftUI wearing the mockup's colours. It was
never designed. It is the only screen a reader reaches by tapping a gear in the
Library header — it has no place in the tab bar.

## What is on it today, in order

### 1. Account
An optional MangaBaka API token. **The app is fully usable without one** — every
discovery endpoint answers unauthenticated (verified: rising, search, series
detail, blends, tags, genres). A token adds: your library sync, personalised
recommendations, and your top-genres taste profile.

Four states the design must cover:
- **Unverified** — a token is stored but has never been checked
- **Checking** — a request is in flight
- **Valid** — with the account it belongs to
- **Invalid** — token rejected, with what to do

Controls: a secure text field, a "Save token" button, and a way to remove one.

### 2. Formats
Which publication formats appear in results — manga, manhwa, manhua, novel, etc.
Multi-select.

### 3. Content ratings
Safe · Suggestive · Explicit. **Safe cannot be switched off** — a reader who
excluded everything would get an empty app with no explanation, so it is
repaired on load. The design needs a way to show a locked-on row that does not
read as broken. Today it says "Always included", which is honest but plain.

Changing this **discards cached feeds**, because a cached feed was fetched under
the old filter. That is a real, visible refetch — worth acknowledging in the UI.

### 4. Blocked tags
A free-text list of tags the reader never wants to see. Global — it applies to
every screen. Add and remove.

### 5. Attribution
**Settled 2026-09-10, and it is a requirement rather than a courtesy.**

MangaBaka's Data License §6.5: *"Applications, websites, or services that display
data obtained from the MangaBaka API or database downloads must include a visible
attribution to MangaBaka."* Their API docs accept any of: a link in the footer, a
link in the About page, or a link next to the specific series.

Two obligations, not one:
1. **A visible link to MangaBaka**, somewhere a reader can find.
2. **Credit to the underlying provider** wherever third-party data is shown —
   AniList, MyAnimeList, MangaUpdates, Anime-Planet and Kitsu all appear in this
   app's cross-tracker score row, and each has its own attribution rules.

No logo, string or placement is specified, so the design has real latitude — but
"visible" is the word in the licence, and a link buried three taps down in
Settings is the interpretation to be able to defend. The series detail screen's
tracker-score row is arguably the more honest home for the second obligation,
since that is where the third-party data actually is.

## Constraints that are not negotiable

- **The switch is drawn, not a real `Toggle`.** The system control only ever
  responded to a drag, never a tap, verified repeatedly on device. If your design
  wants a standard iOS toggle, say so explicitly and I will spend another hour on
  the root cause — do not assume it works.
- **Dynamic Type to the largest accessibility size.** Settings rows were the
  first thing to break here: fixed heights around scaling text made one row's
  caption overlap the next row's title.
- Bottom clearance is 96pt for the floating tab bar. 24 is not enough.

## What to hand back

Every section in its resting state, plus: token invalid, token checking, an empty
blocked-tag list, and one row at the largest accessibility text size.

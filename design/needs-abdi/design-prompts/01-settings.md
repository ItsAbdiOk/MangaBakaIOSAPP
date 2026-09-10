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
Where MangaBaka gets credited. **Unsettled — see question 2.**

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

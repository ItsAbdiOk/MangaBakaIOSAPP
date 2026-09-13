# MangaBaka — design system mirror

MangaBaka is a **SwiftUI app for iOS 26** (dark only, no light mode). This project
is a hand-built **web mirror** of its design system, so designs made here map
back onto real code.

Read this before designing anything.

## What this is, and what it is not

- **The tokens are exact.** Every colour, radius, spacing, control height and type
  size in `styles.css` was copied from the app's own source
  (`MangaBaka/DesignSystem/{Palette,Typography,Metrics,Motion}.swift`) on
  2026-09-14. Design with them and the result is buildable as-is.
- **The components are lookalikes.** They are HTML re-creations of SwiftUI views,
  faithful in appearance and copy, but they are not the app's code and they do
  not carry its behaviour. Treat them as the vocabulary, not the implementation.
- **Anything you invent has to be built by hand in Swift.** A new component is a
  real cost; a rearrangement of existing ones is nearly free. Prefer the second.

## The rules the app actually enforces

1. **Raised surfaces are translucent white over the ground** — `--surface`,
   `--surface-chip`, `--surface-field`, `--surface-active`. Never a solid grey.
2. **Every border is 0.5px** (`--hairline-width`). A 1px border is a bug.
3. **Text has exactly four levels** plus two specials (`--text-emphasis` for the
   detail hero title, `--text-quaternary` for provenance). A value between the
   levels is a mistake, not a nuance.
4. **`--on-accent` on an accent fill, never white** — white on `--accent` fails
   contrast.
5. **Amber (`--stale`) means one thing: what you are looking at is real but out
   of date.** Not a warning, not an accent. If a second thing wants amber, stop.
6. **A disabled control is a different control, not a faded live one.** Chip fill
   plus `--text-muted`; an accent fill at reduced opacity is an outright contrast
   failure exactly when the reader is trying to work out why they cannot press it.
7. **Nothing tappable is under 44px** (`--tap-target`), whatever the drawn size.
8. **Content scrolls under the floating tab bar**; `--scroll-bottom-inset` (124px)
   is what clears it. Do not put a control in that band.
9. **Motion is one of four presets** (`--motion-snappy`, `--motion-settle`,
   `--motion-glide`, and the staggered arrival). All of them honour
   `prefers-reduced-motion`, and so must anything you add.
10. **No real cover art.** Placeholders only — the app's covers are licensed.

## How a polish pass works

1. A brief lands in `briefs/<screen>.md` with the screen's current screenshot,
   what feels off, and what must not change.
2. You design against the components in this project, using the tokens.
3. The result is read back by Claude Code, diffed against the app, and
   implemented as token and view edits — so a spacing change is one number, not a
   rewrite.

Keep changes inside the existing vocabulary wherever they can be. The point of
this mirror is that a design made here is a day of work, not a quarter.

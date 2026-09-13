# Search review — status, 2026-09-13

60 deduped findings (SUMMARY.md §4). Verified against the current source by two
read-only agents after the fixes landed, then updated for `ab4ba67`.

- **Fixed: 56** — commits `1b8d2ae` (state machine, budget, wire, 429, tag picker),
  `920d964` (tags as ids, genres, grid), `99be458` (`.searchable`, tokens, scopes,
  suggestions, hold menu), `ab4ba67` (lossy page decode, offline total). Rows 1–30,
  32–34, 36–57, 59 all fixed; #31's symptom (stagger on scroll-in cards) is closed by
  `arrivalIndex` limiting the stagger to the first three rows rather than by changing
  `Motion.stagger`'s cap; #51 by `LossyArray`; #52/#53 by `OfflineCatalogue.page`
  returning the filtered set's size; #56 re-measured today (`/v1/tags?q=` honoured).
- **Partial: 2**
  - #35 — three debounce constants (300 ms search, 350 ms count, 250 ms tag search)
    are each named and labelled a guess but not unified. Unifying them is a taste call;
    a different guess is still a guess.
  - #58 — the lens bookmark is 52pt and the footnote explains it before the tap, but a
    tap while it is disabled is still silent (no haptic or toast).
- **Open, platform: 1** — #60, the AutoFill chip: there is no `textContentType` that
  means "nothing"; autocorrection and auto-capitalisation are off on the field.

Verified on the simulator (live-walk-2.md, attempts 3 and 4): Tags-chip dead-end gone;
Genres → Romance 81,123 results; "zzzzqqq" empty state with its filter note; hold menu
(Save / Mark read / Open / Copy cover); Cancel returns to idle; "Show results" greys out
when there is nothing to show. Not verified on a device: keyboard rising on tab tap.

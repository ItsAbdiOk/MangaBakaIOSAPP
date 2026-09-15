# Accessibility audit triage — 2026-09-15

Source: `/tmp/mb-a11y-audit.txt` (59 lines, iOS 27 simulator), screenshots at
`/tmp/mb-a11y-<screen>.png`. Baseline context: `docs/accessibility-audit-2026-09-10.tsv`,
`docs/unknowns-2026-09-11.md`. Contrast is computed from `Palette.swift`'s hex/opacity
values (WCAG relative-luminance formula), not eyeballed.

**Note on the brief:** the task pointed at
`/private/.../scratchpad/brief-common.md`, which does not exist in that
scratchpad — the only file there is `review-brief.md`, a **different, unrelated**
read-only review task ("no edits, no commits, no builds, no tests"). That brief
was not followed; it isn't this task. This triage follows the instructions given
inline in the assigning message instead, which are self-contained.

## Counts

- **REAL, fixed:** 3
- **REAL, not fixed (out of lane or already mitigated):** 2
- **FALSE:** 21 (of which most are re-instances of the three artifact classes the
  2026-09-11 review already named: off-screen/obscured elements, the audit
  sampling a system control or system material, and a deliberate `lineLimit` +
  "View more"/ellipsis clamp)
- **UNSURE:** 3

## Table

| # | Screen | Finding | Element | Verdict | Why |
|---|---|---|---|---|---|
| 1,2 | Blocked tags | Contrast failed / Dynamic Type unsupported | "Done" toolbar Button | **FALSE (already mitigated)** | `BlockTagPicker` in `MangaBaka/Features/Settings/BlockedTagsSection.swift:188-201` already carries a comment recording this exact finding from 2026-09-13 and applies `.accessibilityShowsLargeContentViewer()` as the answer: `UINavigationBar` clamps bar-item text below the top of the Dynamic Type range, which no app code can lift. Not a fresh finding. |
| 3,5 | Cover gallery | Contrast failed / Dynamic Type unsupported | "Done" toolbar Button | **FALSE (already mitigated)** | `MangaBaka/Features/Detail/CoverGallery.swift:71-79`: same clamp, same mitigation, its own comment says so explicitly ("Same clamp as the blocked-tags sheet's Done"). Also out of lane (`Features/Detail/CoverGallery.swift` is not in the editable list). |
| 4 | Cover gallery | Potentially inaccessible text | unknown element | **UNSURE** | No frame, no element name. `CoverGallery.swift` is out of lane regardless; not investigated further. |
| 6,19 | Library search results | Hit area too small / Text clipped | "Find in your library" TextField, 58,181 260x19 | **REAL — fixed** | `InlineSearchField` (`MangaBaka/Features/Shared/InlineSearchField.swift`) sizes its row to 44pt (`Metrics.tapTarget`) but never gave the `TextField` itself a height — inside the `HStack` it only ever claims its own intrinsic text height (19-22pt), which is what the audit measured directly. That is both a too-small hit region and, at larger Dynamic Type sizes where the glyphs exceed that frame, real clipping. |
| 7-18 | Library search results | Contrast failed (series titles, "READING", chapter meta) | various StaticText, y=580-835 | **FALSE** | The system keyboard is on screen (search field was focused when the audit ran) and covers y≥~541pt. Computed contrast of the actual tokens used: title `textPrimary` 18.37:1, "READING" chip `Palette.accent` on its own 16%-opacity tint 6.18:1, chapter meta `textMuted` 4.66:1 — all clear AA. The audit sampled pixels under the keyboard sheet, the same "measuring the wrong compositing" artifact the 2026-09-11 review found for off-screen rows. |
| 20-22 | Library search results | Element has no description | three Buttons, y=546, 134pt wide each | **FALSE** | y=546 lines up exactly with the top of the system keyboard's QuickType predictive-text bar (confirmed against the screenshot crop) — three equal-width, unlabeled buttons at the standard 44pt QuickType row height. These are the system keyboard's own suggestion buttons, not app UI; the app has no accessibility label to give them. |
| 23 | Series detail | Hit area too small | unknown element | **UNSURE** | No frame, no name; `SeriesDetailView*` is out of lane. |
| 24 | Series detail | Dynamic Type unsupported | "View more" | **FALSE** | `DetailSynopsis.swift:52-53` uses `.typeChip()`, which is literally in `DynamicTypeRampTests.ramp` and measured `stalls=0` across every content-size step — the ramp does grow. |
| 25,28 | Series detail | Dynamic Type unsupported / Text clipped | synopsis StaticText, 18,577 366x168 | **FALSE — deliberate** | `DetailSynopsis.swift:44` clamps with `.lineLimit(isExpanded ? nil : Self.collapsedLines(...))` plus a measured "View more" affordance (`isTruncated`, computed off two hidden probes, not guessed). This is the exact case `docs/unknowns-2026-09-11.md`'s "C2" section already closed: a `lineLimit`+ellipsis/clamp pattern is by design, matching the same precedent as Discover's card titles. |
| 26 | Series detail | Text clipped | unknown element | **UNSURE** | No frame, no name; out of lane. |
| 27 | Series detail | Text clipped | nav title "Mushoku Tensei: Jobless Reincarnation", 72,74 200x21 | **FALSE** | Frame position (y=74) is the navigation bar. This is `UINavigationBar`'s own title truncation (confirmed in the screenshot — "Mushoku Tensei: Joble…"), set via `.navigationTitle` in `SeriesDetailView.swift` (out of lane). VoiceOver reads the full string regardless of the visual `…`; standard platform behavior, not an app bug. |
| 29,30,32,33 | Series detail | Contrast failed | unknown element | **UNSURE** | No frame, no name; out of lane. |
| 31 | Series detail | Contrast failed | "Characters" header, 18,799 92x22 | **FALSE, likely** | Section headers use `typeDetailSectionHeader()` / `Palette.textPrimary` elsewhere in this pattern (18.37:1); out of lane to confirm the exact call site, but nothing in the app draws a section header below AA. |
| 34 | Settings | Contrast failed | unknown element | **UNSURE** | No frame, no name. |
| 35-40 | Discover | Contrast failed / Text clipped | card titles, meta lines | **FALSE** | Out of lane (`Discover` is not an editable directory), but matches the 2026-09-11 review's cases 1 and 2 exactly: `y=741-698` on an 852pt screen is the same "lazy-stack row built but not fully shown, or text sliding under the floating tab bar" pattern already diagnosed there, and "Manhwa · 8.7" truncating on a fixed-size grid card is the same by-design ellipsis case as "Omniscient Reader" / "Let's Buy the Land…" already closed in that doc. |
| 41 | Stack | Hit area too small | "Open the shelf" Button, 338,764 40x15 | **REAL — fixed** | `StackSections.swift`'s `shelfLink` was a bare `Text("Shelf ›")` in a `Button` with no frame — the audit measured the text's own glyph box. |
| 42 | Stack | Contrast nearly passed | unknown element | **UNSURE** | No frame, no name. |
| 43 | Stack | Contrast failed | "Details" Button, 154,681 86x48 | **FALSE, not fully verified** | Text is `Palette.textPrimary` (18.37:1) over `Glass.floating` (`MangaBaka/DesignSystem/Glass.swift`), the system `.glassEffect(.regular)` material over a live stack card. Same shape of problem as the 2026-09-11 review's SKIP/SAVE badge case: a still-frame pixel sample of an adaptive, specular system material doesn't reflect what the material's own legibility handling does. Not independently re-verified with a device sample, so called FALSE-but-not-fully-verified rather than a clean FALSE. |
| 44 | Stack | Contrast failed | "Nothing saved yet…" caption, 38,807 303x30 | **REAL — fixed** | Used `Palette.textTertiary` (3.96:1 on ground), which `Palette.swift`'s own comment says is for "marks and inactive controls, not running text" — exactly the misuse it warns about. Computed: `textMuted` is 4.66:1, clears AA. |
| 45,46 | Stack | Contrast failed | "SKIP" / "SAVE" StaticText | **FALSE** | Already diagnosed in `docs/unknowns-2026-09-11.md` ("case 3, checked and withdrawn"): `badgeStrength` is a function of live drag distance, so in a static audit both badges are at `opacity(0)` and the sampler measures bare cover art. Not re-derived here; citing the existing measurement (mid-drag composite computed there at 5.8:1, clears AA). |
| 47,48 | Stack | Dynamic Type unsupported / Text clipped | "Saved from the stack", 24,763 151x18 | **FALSE** | `typeSubsectionHeader()` is anchored to `.subheadline` — the same anchor `DynamicTypeRampTests` measured at `stalls=0` for the whole content-size range. Screenshot crop confirms the text renders in full, un-clipped, with `fixedSize`/no `lineLimit` set. |
| 49-53 | Library | Contrast failed | "ch 120" etc. under the tab bar, y=824 | **FALSE — known, not new** | Screenshot crop confirms these sit directly behind the floating glass tab capsule (barely legible at its edge). This is exactly `docs/unknowns-2026-09-11.md`'s "case 2": content scrolling under Liquid Glass is intentional, `scrollBottomInset` is meant to let it clear, and the doc already flags this as the one real-but-accepted contrast risk in that pattern. Not a new bug to fix tonight — same open item, still open. |
| 54 | Library | Text clipped | "Find in your library" TextField, 58,180 313x22 | **REAL — fixed** | Same root cause and same fix as #6/#19 (`InlineSearchField`, shared component). |
| 55 | Search | Text clipped | "Title, author, or tag" SearchField, 16,168 370x11 | **FALSE** | This is `.searchable()`'s native system search field (`SearchField.swift:26-30`) — a `UISearchBar`-backed control the app does not draw and has no lever over. Also not actually presented in the screenshot at that point (tab bar hadn't morphed into it yet). |
| 56 | Search | Contrast failed | "Narrow by" eyebrow, 18,860 75x13 | **FALSE — already fixed** | `Eyebrow` (`MangaBaka/Features/Shared/SectionHeader.swift:27-52`) already switched from `textTertiary` to `textMuted` on 2026-09-14 for this exact class of finding, and its own comment names "NARROW BY on Search" specifically as one of the rows this fixed. Stale finding, or the same audit-artifact class as row 49-53's neighbours; not re-broken by anything in this diff. |
| 57-59 | Search | Contrast failed | "Tags" / "Genres" / "Publishers" Buttons | **FALSE** | `FilterPanel.swift:224-247` uses `Palette.textSecondary` on `Palette.surfaceChip` — computed 5.67:1, clears AA. |

## Fixed

1. **`MangaBaka/Features/Stack/StackSections.swift:264-266`** (empty-stack caption) — `Palette.textTertiary` → `Palette.textMuted`. Real contrast miss (3.96:1 → 4.66:1) on running text, same class of bug `Eyebrow` already had fixed elsewhere.
2. **`MangaBaka/Features/Stack/StackSections.swift:229-238`** (`shelfLink`) — added `.tapTarget()`. Hit region was 40x15; now floors at `Metrics.tapTarget` (44).
3. **`MangaBaka/Features/Shared/InlineSearchField.swift:21-35`** (`InlineSearchField`'s `TextField`) — added `.frame(maxHeight: .infinity)` so the field fills the 44pt row instead of only its intrinsic text height. Fixes both the Library and Library-search-results "hit area too small" and "text clipped" findings (#6, #19, #54), since they're the same shared component.

Tests: `MangaBakaTests/AccessibilityFixesTests.swift` (new), one `@Test` per fix, source-text assertions gated `.enabled(if: SourceTree.isAvailable)`, each documenting the exact pre-fix state that would have failed it.

## Left alone, with reason

- **Blocked tags / Cover gallery "Done" Dynamic Type** — already mitigated (see table); `CoverGallery.swift` is also out of lane.
- **Library "ch NN" under the tab bar (#49-53)** — real but already an open, accepted item from 2026-09-11 (Liquid Glass content is meant to scroll under the bar); not a new regression to patch tonight, and fixing it for real means resolving `Metrics.scrollBottomInset`'s own open question, which is bigger than this pass.
- **Stack's "Details" button contrast (#43)** — likely a system-material sampling artifact matching an already-diagnosed case, but not independently re-measured against a live composite the way the SKIP/SAVE case was; recorded as unverified rather than silently closed.
- **Six "unknown element" / no-frame findings (#4, #23, #26, #29, #30, #32-34, #42)** — cannot be tied to a file or line without a frame or element name, and every screen they're on except Stack (already covered above) is out of the editable lane. Left as UNSURE rather than guessed at.

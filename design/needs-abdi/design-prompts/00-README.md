# Design prompts — screens the app has but never designed

Six briefs. Each is written from the **shipped code**, not from wishes: every
control, state and string listed is one the app can actually produce today. That
gives a designer real boundaries instead of inventing features that do not exist.

Read these together with `design/briefs/design-brief.md` (tokens, palette, type
ramp) and `design/Mockups/NewBakaManga.html` (the eight screens that *were*
designed). The app is SwiftUI on iOS 26 — Liquid Glass, native tab bar,
dark-first, accent `#F87966`.

| Brief | Screen | Why it needs design |
|---|---|---|
| `01-settings.md` | Settings, all of it | Five sections, zero design |
| `02-states.md` | Empty / error / stale / loading | Six error causes, one layout |
| `03-onboarding.md` | First run | Three pages I wrote as placeholder |
| `04-library.md` | Library / Shelf | Never in any mockup |
| `05-mix-lenses.md` | Save-as-a-lens + Mix filters | Data exists, UI missing |
| `06-app-icon.md` | App icon | Placeholder purple, ships to testers |

**One rule for all six:** if a design needs data the app cannot get, say so
rather than drawing it. Two things in the original mockup were drawn from data
that does not exist, and both cost a rebuild.

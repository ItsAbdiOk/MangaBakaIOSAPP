# Dead-declaration sweep — 2026-09-15

No Periphery (declined 2026-09-10). A token-count sweep instead: every
non-private `func/struct/enum/class/actor/protocol/typealias/var/let`
declared under `MangaBaka/` + `MangaBakaWidgets/` whose name appears exactly
once in app code. 39 hits; the charter's warning held — most are not dead.

| Name | Verdict |
|---|---|
| `ISBNScanner.make/update/dismantleUIViewController`, `makeCoordinator`, `FlowLayout.makeCache/updateCache`, `MangaBakaShortcuts`/`appShortcuts`, `suggestedEntities`, `caseDisplayRepresentations`, `MangaBakaWidgetsBundle` | Protocol / framework entry points. Not dead. |
| `Profile.authType`, `SeriesEdition.countExtra/endDate/startYear`, `LibraryEntry.libraryCount/reasonType`, `SeriesTag.isExplicit`, `SeriesCharacter.russian`, `WikidataCoverage.withSiblings/withEnglishTitle/withNativeTitle` | Decoded payload fields, read by tests only. Kept: a field that mirrors the wire is documentation of the shape (charter §1), and `isExplicit` is what a future explicit-tag rule would read. |
| `*ForTesting`, `TestClock`, `UnauthenticatedTokenProvider`, `cachedResult`, `searchWindow`, `rowCount`, `libraryCacheMoveHasCompleted`, `isFollowingBuild`, `capturesTap`, `BlendDNA.Move.rose` | Test seams, each used by tests. Not dead. |
| `ContentPreferences.includesAdultContent` | Tests only. Left: one line, and the next Settings copy that says "adult content is on" wants it. |
| **`CharacterService.clearOutageMemory()`** | **Behavioural gap (charter §3).** Its doc comment named two callers — the cast Retry and the account-change hook — and neither existed. The cast Retry re-asked a service that answered the remembered refusal for up to 15 minutes, so Retry was inert. Fixed: `SeriesDetailView.swift` cast `retry:` clears it first. Account-change left alone: a cast is not personal. |
| **`HistoryStore.usualReadingHour()`** | **Dead.** Arrived with the "Back to it" nudges (f168fab); the nudge machinery was deleted on 2026-09-14 and this helper outlived it with two tests. Deleted with its tests. Reminders re-date to 09:00 (`ReleaseReminders.place`), which is a guess a future version could replace with this idea — the commit history has it. |

Method: `docs/reviews/night/` — the sweep script is inline in the session,
not committed; it is a `Counter` over identifier tokens, so a name reused in
a string or comment counts as a use. Good enough to find the two above;
not a substitute for a real reachability tool.

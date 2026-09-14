# Bundled assets and their licences

Written 2026-09-14, when the answer to "is this going to the App Store?"
became yes. Before that, licences were explicitly out of scope (the standing
instruction on the previous project was to stop flagging them for something
personal and never distributed). Submission reverses that: everything inside
the `.ipa` is something being redistributed.

**Nothing below is guessed.** Where a licence could not be determined, the
entry says so and says what would settle it. An entry that says "could not
determine" is not a soft yes.

## What is actually in the bundle

`MangaBaka/Resources` and `MangaBakaWidgets` hold every shipped asset. There
are no font files (`find` for `.ttf`/`.otf`/`.woff*` returns nothing, and
neither `Font.custom` nor `UIFont(name:)` appears in any Swift file, and
`Info.plist` has no `UIAppFonts` key) — the app is entirely system fonts.
`Assets.xcassets` contains exactly one image set, the app icon.

| Asset | Size | Licence | How that was established |
|---|---|---|---|
| `Assets.xcassets/AppIcon.appiconset/AppIcon.png`, `-Dark.png`, `-Tinted.png` | 496 KB / 418 KB / 123 KB | Original work for this project; no third-party licence applies | Drawn in-repo — commit `93e8947` "Draw the app icon: three glass cards on white", replacing the placeholder from `e417694`. No source image, stock library or third-party asset appears anywhere in the history for these files. Note the icon is still tracked as an open design question (QUESTIONS.md #6), which is a design matter, not a licensing one. |
| `TagTaxonomy.json` | 696 KB | **CC BY-NC-SA 4.0** — see the conditions below | Stated in `TagTaxonomy.swift`'s own doc comment: MangaBaka's `/v1/tags`, fetched 2026-08-27, 2,686 rows. MangaBaka's Data License §3 puts MangaBaka-original data under CC BY-NC-SA 4.0 (`design/needs-abdi/mangabaka-terms.md`). |
| `OfflineIndex.json.gz` | 1.5 MB | **CC BY-NC-SA 4.0 for the MangaBaka-original fields; undetermined for anything third-party in it** | Derived from MangaBaka data: ids, titles, kind, year, rating, popularity, content rating, status and `tags_v2` ids for the top ~19,300 series (`OfflineCatalogue.swift`). No generation script is in this repo, so the export's exact provenance is recorded only in that file's comments. |
| `OfflineEmbeddings.bin` | 7.5 MB | Same as above, and see the ML note | A bundled export, magic `MBE1`, 19,203 series × 384 dims, Int8-quantised (`EmbeddingIndexTests.swift`, `EmbeddingIndex.swift`). Built from MangaBaka's own data. Which model produced the vectors is **not recorded anywhere in this repo** — see "Could not determine" below. |
| `WikidataIdentity.json.gz` | 440 KB | **CC0 1.0** — public domain dedication, no attribution required, no share-alike, no non-commercial clause | Wikidata's own database is CC0 by policy; the extract is built by `Scripts/generate-wikidata-identity.py` and rebuilt per release. A credit in Settings is courtesy, not an obligation. |
| `PrivacyInfo.xcprivacy` | 3.9 KB | n/a — this project's own file | Written here. |

## Linked code

| Dependency | Version | Licence | How that was established |
|---|---|---|---|
| GRDB.swift | `from: "7.0.0"` (project.yml) | MIT | Read the `LICENSE` file in the resolved checkout: "Copyright (C) 2015-2025 Gwendal Roué … Permission is hereby granted, free of charge …". MIT terms require the copyright notice be included in distributions — an acknowledgements entry in Settings would satisfy that and does not exist yet. |

GRDB is the only third-party dependency. It ships its own
`PrivacyInfo.xcprivacy` declaring no collected data and no required-reason
APIs.

## Apple's own assets

The app draws 29 distinct SF Symbols (`Image(systemName:)` / `systemImage:`).
SF Symbols are licensed by Apple for use in apps under the Xcode and Apple SDK
agreements, with two conditions that bind here: they must not be used as, or
as part of, a logo or trademark, and they must not be modified beyond the
configuration APIs. The app uses them as plain symbols in controls and rows and
does not use one in the icon, so both conditions hold. Verified by reading the
call sites; the terms themselves are Apple's, not restated here.

## The condition that actually needs a decision

**CC BY-NC-SA 4.0 is a NonCommercial licence, and the App Store is the point
at which "non-commercial" stops being obvious.** This is not new — it is
already open question 2 in `design/needs-abdi/QUESTIONS.md`, and that entry
reaches the same conclusion: a free app with no ads and no purchases is *very
probably* fine, and "probably" is doing the work. MangaBaka offers
pay-what-you-want commercial licensing and lists a revenue threshold; both
numbers in that file are second-hand from search summaries rather than a
fetched page, and are not repeated here.

Three separate obligations follow from the licence, and only one of them is
currently met:

1. **Attribution — required, and specified.** Data License §6.5: applications
   displaying MangaBaka data "must include a visible attribution to
   MangaBaka". Settings has a row for this. Whether it is filled in is a
   Features question, not this file's.
2. **ShareAlike — unexamined.** CC BY-NC-SA's SA term applies to adaptations.
   `OfflineEmbeddings.bin` is an adaptation of MangaBaka's data by any
   ordinary reading. Nobody has worked out what SA obliges for a binary blob
   inside a closed-source app. **Unresolved.**
3. **Third-party data — explicitly not licensed to redistribute.** Data
   License §4: MangaBaka holds no redistribution rights for third-party data
   and grants none. The bundled files must therefore contain MangaBaka-origin
   fields only. Nobody has audited `OfflineIndex.json.gz` field-by-field
   against that boundary. **Unresolved**, and the one of the three with a
   concrete failure mode.

The existing practice is consistent with taking this seriously:
`OnboardingTests.shipsNoBorrowedArtwork` already fails the build if any image
other than the app icon appears under `Resources/`, precisely because bundling
cover art would be redistributing publisher artwork.

## Data fetched at runtime from libraries

Nothing here is bundled — these are live calls — but both sources attach
conditions to *use*, not just to redistribution, so they belong in this file.

| Source | Used by | Condition | How that was established |
|---|---|---|---|
| Anime News Network Encyclopedia | `ANNClient` | **Per-entry backlink mandatory** — every volume row shown from ANN renders its own `sourceLink`, and the section names Anime News Network. A footer credit does not satisfy it. | Their API page states the condition; recorded when the client was written, 2026-09-14. |
| Open Library / Internet Archive | `OpenLibraryEditions`, `OpenLibraryCovers` | **No licence is named.** Attribution displayed by choice | Their licensing page asserts no new copyright over the database and concedes the legal issues "are, frankly, very confusing". That is not CC0 and must not be written up as CC0. The credit string lives in `BookEdition.Source.credit`: "Edition data from Open Library". |
| NDL Search (国立国会図書館サーチ) | `NDLClient` | Credit mandatory; **commercial use needs prior application** | NDL's API help, read on 2026-09-14. See the open question below. |

### NEEDS ABDI — NDL's commercial-use term

NDL's API terms, in substance: **non-commercial use requires no application;
commercial use requires prior approval from NDL and from the relevant data
providers**, and credit is mandatory either way. Some of the metadata is
CC BY 4.0, but provider conditions vary per NDL's 提供対象データプロバイダ一覧,
so the CC BY part does not cover the whole answer.

Their exact published wording is Japanese and was not copied verbatim into
this repo; the paraphrase above is what the API help page states, and the page
itself is the authority if this ever has to be argued.

**The question, and it is yours, not the code's:** an App Store app that is
free, ad-free and has no IAP is *arguably* non-commercial, and that is exactly
what "arguably" always means here. If the app ever carries ads, a purchase or
a subscription, the 利用申請 has to be filed first.

This is deliberately **not gated off in code**. `NDLClient` ships and works;
the credit is not optional (`BookEdition.Source.nationalDietLibrary.credit` →
`国立国会図書館サーチ`) and the view that shows an NDL row must carry it. What is
open is whether an application is owed, and that is the same shape as the
MangaBaka NonCommercial question above — the two should be answered together,
since a "yes, this is commercial" makes both of them real at once.

## Could not determine

- **Which model produced `OfflineEmbeddings.bin`.** No generation script is in
  this repo and no comment names one. This matters for two reasons: a model's
  own licence can restrict redistribution of its outputs, and MangaBaka's Data
  License §6.6 treats ML use separately — personal and academic experimentation
  is allowed under the standard licence, commercial training and fine-tuning
  needs a prior written agreement. Settled by finding the sibling project that
  built the file (the same place `TagTaxonomy.json` came from — "Tags Gen") and
  recording the model there.
- **Whether `OfflineIndex.json.gz` contains any third-party-origin field.**
  Settled by listing its fields against MangaBaka's own documentation of which
  fields are theirs.
- **Whether a free App Store app counts as non-commercial for MangaBaka.**
  Their answer, not ours. `legal@mangabaka.org`.

## What is not required

No acknowledgements screen is legally required for CC BY-NC-SA beyond the
visible attribution above, but MIT (GRDB) does require the copyright notice to
travel with the distribution. One Settings row listing GRDB's notice covers it.

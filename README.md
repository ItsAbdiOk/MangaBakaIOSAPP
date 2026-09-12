# MangaBaka for iOS

A discovery-first MangaBaka client for iPhone. Open source, free, and built to
find your next read rather than just to track the last one.

Design and rationale: [`docs/designs/discovery-first-mangabaka-client.md`](docs/designs/discovery-first-mangabaka-client.md)

## Status

In development, and well past scaffold. Discovery feeds, search and tag/author
browsing, the on-device cache, the swipe stack, library sync, release schedules
and character profiles are all built, with around a thousand tests over them.
Not submitted to the App Store.

## Where the data comes from

- **MangaBaka** — the catalogue. Most of it is public; your library needs a token.
- **Apple Books** (iTunes Search) — volume covers, prices and store links.
- **Google Books** — covers for volume numbers Apple does not carry, and nothing
  else. Unauthenticated, so it often returns nothing and the shelf simply shows
  Apple's.
- **AniList**, with **Shikimori** as a fallback — character profiles. Shikimori's
  Russian is translated on-device before it is shown.
- **MangaUpdates** — release history, which is what release estimates are built
  from.
- **Webtoons and Naver** — official per-series feeds, the only source here that
  publishes real release dates rather than letting them be inferred. See
  `docs/release-sources-2026-09-12.md`.

No analytics, no telemetry, no third-party tracking. Nothing is reported
anywhere. No manga content is hosted, cached or served by this app — it is a
catalogue and a tracker, and every reading link points at an official platform
on a checked allowlist.

## Requirements

- Xcode 26 or newer, iOS 26 SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) and
  [SwiftLint](https://github.com/realm/SwiftLint): `brew install xcodegen swiftlint`

## Building

```sh
xcodegen generate
open MangaBaka.xcodeproj
```

`project.yml` is the source of truth for the project. Adding or moving files
means running `xcodegen generate` and committing the regenerated
`MangaBaka.xcodeproj`; CI fails if the two drift apart.

No credentials are needed. Every discovery endpoint is public — 51 of the
API's 77 operations require no authentication at all.

## Optional: authenticated endpoints

Your library and personalised recommendations need a token. Copy
`Configs/Secrets.example.xcconfig` to `Configs/Secrets.xcconfig` (gitignored)
and add a personal access token from your MangaBaka account.

A personal access token never expires and grants full access to your account.
Never commit it, and never ship a build containing one — anyone with the `.ipa`
can extract it.

## Checks

```sh
swiftlint lint --strict                    # force unwraps, tokens, print(), catch-alls
xcodebuild test -project MangaBaka.xcodeproj -scheme MangaBaka \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
python3 Scripts/check-api-contract.py      # has MangaBaka's response shape drifted?
```

A `pre-push` git hook runs the credential check, lint, the project-sync check
and the full test suite before anything leaves your machine. Enable it once
after cloning:

```sh
git config core.hooksPath .githooks
```

Xcode Cloud runs the same credential and lint checks again before building, via
`ci_scripts/ci_pre_xcodebuild.sh`, so a push made with `--no-verify` still
cannot reach TestFlight unchecked.

Run the contract check by hand every so often. The golden fixtures are frozen
snapshots: without it, MangaBaka could change their response shape and every
unit test would still pass while the app broke.

There is deliberately no GitHub Actions workflow — CI runs locally and in
Xcode Cloud instead.

## Attribution

MangaBaka data is licensed **CC BY-NC-SA 4.0**: free for personal and
non-commercial use, with attribution. This app is free and carries no ads or
purchases, which is a deliberate condition of that licence rather than an
accident.

Data comes from MangaBaka and, through it, from AniList, Kitsu, MangaUpdates,
MyAnimeList and Anime-Planet. Attribution to all of them ships in the app.

## Licence

Not yet chosen. See open question 2 in the design doc: whether CC BY-NC-SA's
ShareAlike term reaches this app's source is unresolved and worth settling
before any public release.

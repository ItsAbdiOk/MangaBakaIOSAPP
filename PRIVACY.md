# Privacy Policy — MangaBaka for iOS

Last updated: 10 September 2026

## The short version

This app has no servers of its own, no accounts of its own, no analytics, and
no advertising. Nothing you do in it is sent to the developer, because there is
nowhere for it to be sent.

## What the app stores, and where

Everything the app stores stays on your device.

- **Your library, saves and skips** are held in a database inside the app's own
  storage.
- **Cached series data and cover images** are stored on the device so the app
  works offline and does not re-download the same artwork.
- **A MangaBaka personal access token**, if you choose to enter one, is stored
  in the iOS Keychain, marked as accessible only after first unlock and only on
  that device. It is never written into the app's code, never included in a
  release build, and never transmitted anywhere except to MangaBaka to
  authenticate your own requests.

Deleting the app removes all of it.

## What leaves your device

The app makes requests to three services, and only to fetch data:

- **MangaBaka** (`api.mangabaka.org`) — series, covers, search, and, if you have
  entered a token, your own library and recommendations.
- **MangaUpdates** (`api.mangaupdates.com`) — release history, used to estimate
  when the next chapter of a series you are reading is likely due. No account is
  used and nothing identifying you is sent.
- **Shikimori** (`shikimori.one`) — the cast of a series, shown on its page. The
  request is made only when you open a series that has one, names only that
  series, and uses no account.

As with any request over the internet, those services can see your IP address
and the request you made. Their own privacy policies apply to what they do with
it. This app sends them nothing about you beyond the request itself, and your
MangaBaka token only ever goes to MangaBaka.

## What the app does not do

- No analytics, telemetry, crash reporting, or usage tracking of any kind.
- No advertising, and no advertising identifiers.
- No third-party SDKs.
- No data is collected by the developer. The app's privacy manifest declares
  this, and it is verifiable in the source.
- No account is required. Every discovery feature works without signing in.

## Content settings

The app filters content to "safe" and "suggestive" ratings by default.
Anything stronger is available only if you deliberately turn it on in Settings.
That choice is stored on your device and sent to MangaBaka as a filter on your
requests so that excluded material is never downloaded.

## Children

The app can display mature content if a user opts in, and is rated accordingly.
It is not directed at children.

## Data attribution

Series data comes from MangaBaka, and through it from AniList, Kitsu,
MangaUpdates, MyAnimeList and Anime-Planet. It is licensed under
CC BY-NC-SA 4.0. Release history comes from MangaUpdates, and character
information and portraits from Shikimori.

## Source

The app is open source: https://github.com/ItsAbdiOk/MangaBakaIOSAPP

Every claim on this page can be checked against that source.

## Contact

mo.abdirahman99@gmail.com

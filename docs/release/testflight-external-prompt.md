# Claude-in-Chrome prompt: MangaBaka external TestFlight

Paste into Claude in Chrome with App Store Connect open and signed in. Fill
the tester lines first. Written 2026-09-14 against the live Test Information
(Beta App Review contact, feedback email, privacy policy URL and description
are already set; age rating is not — that is step 1).

---

Team 5AF2LBU5A3, app **BakaManga** (Apple ID 6809923095, bundle
dev.abdirahmanmohamed.mangabaka — the app's display name is MangaBaka).
Report every field before saving. Change nothing not listed here.

1. App Information → Age Rating. It is unset. Open the questionnaire and
   answer for an app that browses a community manga database where the
   default shows only "safe" and "suggestive" series, and stronger content
   (Apple-rated erotica/pornography tags exist in the catalogue) is behind
   an opt-in in Settings. Answer:
   * Sexual Content or Nudity: **Frequent/Intense** (the opt-in exposes
     explicit series covers and synopses).
   * Mature/Suggestive Themes: **Frequent/Intense**.
   * Violence (cartoon or fantasy): **Frequent/Intense**; Realistic
     violence: Infrequent/Mild.
   * Profanity or Crude Humor: Infrequent/Mild.
   * Alcohol, Tobacco, or Drug Use: Infrequent/Mild.
   * Horror/Fear Themes: Infrequent/Mild.
   * Medical/Treatment, Gambling, Contests: None.
   * Unrestricted Web Access: **No** (links open in an in-app Safari view to
     specific known sites only). Gambling: No.
   * If Apple's newer questionnaire asks age-assurance / "made for kids":
     Not made for kids.
   The resulting rating should be **18+** (or 17+ on the old scale). If it
   comes out lower, stop and tell me which answer to change.

2. TestFlight → External Testing. Open the group **"Friends"** (create it if
   it does not exist). Public Link **OFF**.

3. Add testers to "Friends" by email:
   * <BROTHER_EMAIL> (first name <FIRST>, last name <LAST>)
   * (add more lines later)

4. Add the latest processed build of the **highest marketing version**
   (1.1.0 if it exists, else 0.1.0 — never 1.0, those are stale) to
   "Friends". When it asks:
   * Export compliance: the build's Info.plist already declares
     ITSAppUsesNonExemptEncryption = false, so it should not ask. If it
     does: standard HTTPS only, no proprietary encryption → exempt.
   * "What to Test" for this build: reuse the text already on the build
     (it is set from the commit subject); if empty, use:
     "Open Discover and tap into three series. On a series page, scroll to
     'Volumes on record' and tick a volume you own — check the 'You own N of
     M' line makes sense. Try Search with a typo and with a genre from
     Browse → Tree. Add a series to your library (needs a MangaBaka token
     from Settings — skip if you don't have one). Report anything confusing,
     wrong, slow, or any series that shows the wrong volumes."
   * Beta App Review contact: already filled (Abdirahman Mohamed). Sign-in
     required: **NO** — no account is needed to review. If any required
     field is blank, stop and tell me which.

5. Submit that build for Beta App Review. Confirm the status shows
   "Waiting for Review" (or "In Review").

6. Under the "Friends" group settings, turn **ON** automatic distribution of
   new builds ("Automatically distribute new builds" / "Enable automatic
   distribution"), so later builds of that version reach the group
   without re-adding.

Report: age rating result, build number submitted, review status, testers
in the group, and whether automatic distribution is on.

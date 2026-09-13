import Foundation
import Testing
@testable import MangaBaka

/// `MissingVolumeCover.caption(apple:openLibrary:)` — the line under the
/// dimmed placeholder that tells a reader why a volume has no cover, rather
/// than letting a blank box read as the app being broken (the actual report:
/// The Beginning After the End, Yen Press — no Apple Books listing, no Open
/// Library ISBN cover).
///
/// Before this item neither `MissingVolumeCover` nor its call sites had any
/// notion of "asked" — a volume nobody had looked up yet and a volume both
/// sources had given up on drew identically. `caption(apple:openLibrary:)`
/// and `SourceState` did not exist at all, so every test below is fail-first
/// by construction: it could not have compiled, let alone passed, against
/// the prior code.
@Suite("The missing-cover caption")
struct MissingVolumeCoverCaptionTests {
    /// Both sources have had their say and neither found anything — the one
    /// case worth telling the reader about.
    @Test("Both sources answered with nothing: says so")
    func bothAnsweredNothing() {
        #expect(
            MissingVolumeCover.caption(apple: .answered, openLibrary: .answered)
                == "No cover from the publisher"
        )
    }

    /// Nobody has looked yet — "nothing special", per the item, not a
    /// premature "no cover" claim.
    @Test("Neither source has been asked yet: says nothing")
    func neitherAskedYet() {
        #expect(MissingVolumeCover.caption(apple: .notAsked, openLibrary: .notAsked) == nil)
    }

    /// Apple has already answered (both call sites only ever reach this view
    /// once it has — see their own comments), but Open Library's pass has
    /// not run yet — nothing worth saying, since it might still fill the gap.
    @Test("Open Library hasn't been asked yet: says nothing, even though Apple has")
    func openLibraryNotAskedYet() {
        #expect(MissingVolumeCover.caption(apple: .answered, openLibrary: .notAsked) == nil)
    }

    /// A source still out should never be treated as a "no" — a caption said
    /// now could be contradicted a moment later when it answers.
    @Test("A source still loading: says nothing, not a guess")
    func sourceStillLoading() {
        #expect(MissingVolumeCover.caption(apple: .answered, openLibrary: .loading) == nil)
        #expect(MissingVolumeCover.caption(apple: .loading, openLibrary: .answered) == nil)
    }
}

/// `accessibilityText(apple:openLibrary:)` is what both `VolumesSection` and
/// `AppleVolumesRow` actually put in their spines' VoiceOver labels — routed
/// through this one function so the spoken text can never drift from the
/// on-screen caption.
@Suite("The missing-cover VoiceOver text matches the caption")
struct MissingVolumeCoverAccessibilityTextTests {
    /// When there's a caption to say, VoiceOver says exactly that — not a
    /// second, differently-worded string.
    @Test("Both sources answered: VoiceOver text is the caption, verbatim")
    func matchesCaptionWhenBothAnswered() {
        let caption = MissingVolumeCover.caption(apple: .answered, openLibrary: .answered)
        #expect(MissingVolumeCover.accessibilityText(apple: .answered, openLibrary: .answered) == caption)
    }

    /// Before there's anything specific to say, VoiceOver still needs to say
    /// *something* — a sighted reader sees a dimmed cover either way, but a
    /// VoiceOver reader has no visual to fall back on, so the generic
    /// "cover not available" carries the load the caption doesn't yet.
    @Test("Nothing to say yet: VoiceOver still says the cover isn't there")
    func fallsBackWhenNoCaption() {
        #expect(MissingVolumeCover.caption(apple: .notAsked, openLibrary: .notAsked) == nil)
        #expect(
            MissingVolumeCover.accessibilityText(apple: .notAsked, openLibrary: .notAsked)
                == "cover not available"
        )
        #expect(
            MissingVolumeCover.accessibilityText(apple: .answered, openLibrary: .loading)
                == "cover not available"
        )
    }
}

import Foundation
import Testing
@testable import MangaBaka

/// Naming the publisher a release date came from. See `ReleaseSource`.
///
/// The volumes shelf already names Apple and Google in its header; releases
/// read the same way so one page does not attribute two sections differently.
@Suite("Release source attribution")
struct ReleaseSourceTests {
    private func source(_ text: String) -> ReleaseSource? {
        guard let url = URL(string: text) else { return nil }
        return ReleaseSource.serving(url)
    }

    @Test("Each confirmed platform is recognised from its link")
    func recognisesPlatforms() {
        #expect(source("https://www.webtoons.com/en/fantasy/tower-of-god/list?title_no=95")
                == .webtoons)
        #expect(source("https://comic.naver.com/webtoon/list?titleId=183559") == .naverWebtoon)
        #expect(source("https://tonarinoyj.jp/episode/13932016480028985383") == .youngJump)
    }

    /// The header the reader actually sees, and the reason the section exists:
    /// three bare rows from one publisher and a full schedule from another is
    /// not inconsistency, and the name is what says so.
    @Test("The header names the publisher")
    func headerNamesPublisher() {
        #expect(ReleaseSource.webtoons.attribution == "Releases · Webtoons")
        #expect(ReleaseSource.naverWebtoon.attribution == "Releases · Naver Webtoon")
        #expect(ReleaseSource.youngJump.displayName == "Tonari no Young Jump")
    }

    /// An unnamed source is one the reader cannot weigh, so it gets no section
    /// rather than an anonymous one.
    @Test("A platform that serves no release data is not a source")
    func unknownPlatformsAreNotSources() {
        #expect(source("https://tapas.io/series/solo-leveling-comic/info") == nil)
        #expect(source("https://manta.net/en/series/x") == nil)
        #expect(ReleaseSource.serving(nil) == nil)
    }

    /// Same engine, endpoint switched off: both answered
    /// `{"error":{"message":"wrong feature"}}` when probed on 2026-09-12, so
    /// naming them would promise data that never arrives.
    @Test("GigaViewer siblings with the endpoint disabled are excluded")
    func disabledSiblingsExcluded() {
        #expect(source("https://shonenjumpplus.com/episode/3269632237275906867") == nil)
        #expect(source("https://comic-days.com/episode/13932016480029466292") == nil)
    }

    /// Matching on a label boundary, the same rule `ReadingPlatforms` uses, or
    /// a lookalike host would be attributed to a publisher it has nothing to
    /// do with.
    @Test("A subdomain counts; a lookalike does not")
    func matchesOnLabelBoundary() {
        #expect(source("https://m.comic.naver.com/webtoon/list?titleId=1") == .naverWebtoon)
        #expect(source("https://notwebtoons.com/en/x/list?title_no=1") == nil)
        #expect(source("https://webtoons.com.evil.example/x") == nil)
    }
}

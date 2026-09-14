import AppIntents
import Foundation

/// "Open this in MangaBaka" — a link the reader was sent, from the share
/// sheet or Shortcuts/Siri.
///
/// **Share-sheet eligibility, as documented for this task**: a `URL`
/// `@Parameter` plus `AppShortcutsProvider` registration with
/// `openAppWhenRun = true` is exactly how `OpenSeriesIntent` already reaches
/// Siri and Shortcuts, so that much is proven by this codebase, not assumed.
/// Whether that alone is *also* sufficient for the intent to be offered in
/// the iOS share sheet specifically could not be confirmed from Apple's docs
/// this session — `developer.apple.com/documentation/appintents/…` pages
/// fetched as bare titles with no body (JS-rendered), and web search turned
/// up no page stating the exact rule. Flagged unverified rather than
/// asserted; see this task's report for the fast way to settle it (share a
/// mangabaka.org/AniList/etc. link on a device and see if MangaBaka is
/// offered).
struct OpenSharedURLIntent: AppIntent {
    static let title: LocalizedStringResource = "Open a shared link"
    static let description = IntentDescription(
        "Opens a series from a link — mangabaka.org, AniList, MyAnimeList, MangaUpdates or MangaDex."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Link")
    var url: URL

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$url) in MangaBaka")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let target = SharedURLResolver.target(from: url) else {
            return .result(dialog: "That doesn't look like a series link MangaBaka recognises.")
        }
        guard let services = IntentBridge.shared.services else {
            return .result(dialog: "Open MangaBaka first, then try that link again.")
        }
        guard let seriesId = await Self.seriesID(for: target, wikidata: services.wikidata) else {
            return .result(dialog: IntentDialog(stringLiteral: Self.notFoundDialog(for: target)))
        }
        IntentBridge.shared.pending = IntentBridge.Open(id: seriesId)
        return .result(dialog: "Opening it now.")
    }

    /// `target`'s MangaBaka series id, through whichever lookup exists for
    /// its tracker.
    ///
    /// `.mangaBaka` needs none — a mangabaka.org link already carries a
    /// MangaBaka id. The three trackers go through `WikidataIdentityTable`'s
    /// id indexes, which are exact joins — never a title search, which could
    /// land on the wrong series. A tracker id the table has not seen answers
    /// nil, and the table covers a quarter of the catalogue by row, so nil is
    /// "not known here", not "does not exist". `.mangaDex` never resolves: no
    /// MangaDex id appears anywhere in this app's models or offline tables
    /// (checked: `grep -ri mangadex` across `MangaBaka/` before writing
    /// this found nothing but this task's own new files).
    static func seriesID(for target: SharedURLTarget, wikidata: WikidataIdentityTable) async -> Int? {
        switch target {
        case let .mangaBaka(id):
            return id
        case let .aniList(id):
            return await wikidata.identity(aniListID: id)?.mangaBakaID
        case let .myAnimeList(id):
            return await wikidata.identity(myAnimeListID: id)?.mangaBakaID
        case let .mangaUpdates(id):
            return await wikidata.identity(mangaUpdatesID: id)?.mangaBakaID
        case .mangaDex:
            return nil
        }
    }

    /// What a reader hears when `target` parsed fine but nothing in the app
    /// could resolve it to a series — see `seriesID(for:wikidata:)` for why
    /// each of these currently answers nil.
    static func notFoundDialog(for target: SharedURLTarget) -> String {
        switch target {
        case .mangaBaka:
            // Unreachable in practice — `seriesID` always resolves this
            // case — but a switch here stays exhaustive rather than a
            // default that would silently swallow a new case later.
            return "Couldn't open that link."
        case .aniList, .myAnimeList, .mangaUpdates:
            return "MangaBaka doesn't have a match for that series yet."
        case .mangaDex:
            return "MangaBaka can't look up MangaDex links yet."
        }
    }
}

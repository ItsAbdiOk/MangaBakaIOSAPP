import Foundation
import Translation

/// Turns a Russian `CharacterDescription` into an English one, span by span,
/// using Apple's on-device Translation framework.
///
/// **Why after parsing, not before.** `ShikimoriDescriptionParser` runs first
/// and turns Shikimori's BBCode into spans/blocks; only the plain, bold and
/// italic *text* of each span — never a `[b]`, a URL, or a spoiler marker —
/// is ever handed to the translator. Markup surviving a machine translation
/// usually comes back mangled (tags translated as words, or dropped
/// entirely), and there would be no reliable way to re-attach a translated
/// tag to the right span afterwards. Parsing first means the translator only
/// ever sees prose, and the structure it returns into is the structure that
/// went in.
///
/// **Why this can never show Russian.** `CharacterProfileView` only calls
/// this for a Shikimori-sourced profile (`CharacterProfile.requiresTranslation`)
/// and drops the description whenever this throws — no case in
/// `CharacterProfileView` ever renders an untranslated block. See that type's
/// `beginShowing` and `translateIfNeeded`.
enum CharacterDescriptionTranslator {
    /// Thrown when the translation session answered with a different number
    /// of responses than requests. Treated as a failure rather than risking
    /// a span showing text translated for a different span.
    struct ResponseCountMismatch: Error {}

    /// Translates every span's own text, preserving exactly which spans were
    /// bold, italic, a link, or inside a spoiler block.
    ///
    /// Not `@MainActor`, for the same reason `SystemDescriptionTranslator`
    /// is not: the translator it is handed wraps a non-Sendable
    /// `TranslationSession`, and isolating this to the main actor made every
    /// call send that translator across an isolation boundary.
    static func translate(
        _ description: CharacterDescription,
        using translator: some DescriptionTranslating
    ) async throws -> CharacterDescription {
        let texts = description.blocks.flatMap { block in block.spans.map(text(of:)) }
        guard !texts.isEmpty else { return description }

        let translated = try await translator.translations(for: texts)
        guard translated.count == texts.count else { throw ResponseCountMismatch() }

        var cursor = 0
        var blocks: [CharacterDescription.Block] = []
        for block in description.blocks {
            var spans: [CharacterDescription.Span] = []
            for span in block.spans {
                spans.append(rebuilt(span, translatedText: translated[cursor]))
                cursor += 1
            }
            blocks.append(CharacterDescription.Block(spans: spans, isSpoiler: block.isSpoiler))
        }
        return CharacterDescription(blocks: blocks)
    }

    private static func text(of span: CharacterDescription.Span) -> String {
        switch span {
        case let .plain(text), let .bold(text), let .italic(text): text
        case let .link(text, _): text
        }
    }

    /// Same span shape, translated text — a link keeps its original URL, a
    /// bold span stays bold, and so on. Only the words move.
    private static func rebuilt(
        _ span: CharacterDescription.Span, translatedText: String
    ) -> CharacterDescription.Span {
        switch span {
        case .plain: .plain(translatedText)
        case .bold: .bold(translatedText)
        case .italic: .italic(translatedText)
        case let .link(_, url): .link(text: translatedText, url: url)
        }
    }
}

/// The seam between `CharacterDescriptionTranslator` and Apple's Translation
/// framework, so the span-rebuilding logic above can be tested with a fake —
/// a real `TranslationSession` needs a live SwiftUI `.translationTask` and a
/// language pack that may or may not be installed on the test machine,
/// neither of which a unit test controls.
///
/// `@MainActor` rather than `Sendable`: `TranslationSession` is a SwiftUI-vended
/// object handed to `CharacterProfileView`'s `.translationTask` closure, which
/// already runs on the main actor — isolating the protocol to match is what
/// lets `SystemDescriptionTranslator` hold one without asserting it is safe
/// to send across threads, which is not this file's claim to make.
protocol DescriptionTranslating: Sendable {
    /// Translates each string independently, returning the same count in the
    /// same order. A conforming type that cannot guarantee the order must
    /// restore it itself — `CharacterDescriptionTranslator` assumes
    /// `translated[i]` is the translation of `texts[i]`.
    func translations(for texts: [String]) async throws -> [String]
}

/// Wraps a live `TranslationSession`.
///
/// Deliberately NOT `@MainActor`. `TranslationSession` is non-Sendable and
/// `translations(from:)` is nonisolated, so isolating this type to the main
/// actor made every call send the session across an isolation boundary —
/// "sending 'self.session' risks causing data races", a hard error under
/// Swift 6. The session is used exactly where `.translationTask` hands it
/// over and never stored anywhere it could outlive that, which is the
/// property that actually matters here.
/// **`@unchecked Sendable`, and why.** `TranslationSession` is a plain
/// non-Sendable class whose methods are nonisolated and `async`, so awaiting
/// one from any isolated context is a Swift 6 error ("sending 'self.session'
/// risks causing data races") — while the session itself is only ever handed
/// out inside SwiftUI's main-actor `.translationTask` closure, which cannot
/// pass it anywhere else without the same error. The two constraints leave no
/// safe-by-inference spelling, so the promise is made here instead of worked
/// around.
///
/// The invariant that makes it true: this wrapper is constructed inline at its
/// one call site from the session `.translationTask` just provided, used for a
/// single sequential run of awaits, and dropped. It is never stored, never
/// escapes that callback, and no two of them exist for one session. If anyone
/// caches one of these, the promise is void.
struct SystemDescriptionTranslator: DescriptionTranslating, @unchecked Sendable {
    let session: TranslationSession

    /// One string at a time, deliberately, rather than
    /// `TranslationSession.translations(from:)`.
    ///
    /// The batch API takes `[TranslationSession.Request]`, and `Request` is
    /// not `Sendable` — nor is `TranslationSession` itself, which is a plain
    /// class. Passing either across an isolation boundary is a hard error
    /// under Swift 6 ("sending 'requests' risks causing data races"). The
    /// single-string call takes a `String` and returns a `Sendable`
    /// `Response`, so nothing that crosses here needs a promise this file
    /// cannot make.
    ///
    /// Sequential rather than concurrent, which also removes the reason the
    /// batch version needed `clientIdentifier` at all: a loop cannot return
    /// results out of order, so `translated[i]` belongs to `texts[i]` by
    /// construction. A character description is a handful of spans, not a
    /// workload worth parallelising.
    func translations(for texts: [String]) async throws -> [String] {
        var out: [String] = []
        out.reserveCapacity(texts.count)
        for text in texts {
            out.append(try await session.translate(text).targetText)
        }
        return out
    }
}

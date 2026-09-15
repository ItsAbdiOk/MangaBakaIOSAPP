import SwiftUI

/// Every other name this series goes by.
///
/// A series carries one title per language — 25 of them on Solo Leveling,
/// verified live on 2026-09-11 — and the app showed exactly one. The website
/// offers "Show 36 more titles" and we offered none, which matters more than
/// it sounds: a reader who knows a series as "Ore Dake Level-Up na Ken" or
/// "나 혼자만 레벨업" has no way to confirm from this page that they are
/// looking at the same book.
///
/// It lives in the hero, under the byline, because that is where a reader
/// looking for a name they recognise will look — the question "is this the
/// same book?" is asked on arrival, not two screens down. One line with a
/// count, opening a sheet: the list is a reference, not something to read on
/// the way past, and inlining twenty-five names would push the synopsis off
/// the screen.
/// The line in the hero. One tap, one sheet.
struct AlternativeTitlesButton: View {
    let titles: [SeriesTitle]
    /// The one already on screen, which should not be counted or repeated.
    let shown: String?
    /// `romanized_title` / `native_title` / `secondary_titles` from
    /// `/v1/series/{id}` — three more places names live, outside the
    /// `titles` array itself. Optional and defaulted so an existing caller
    /// that only knows about `titles` keeps compiling; a caller wanting
    /// these shown passes them explicitly. See `SeriesRecordFieldsTests`.
    var romanizedTitle: String?
    var nativeTitle: String?
    var secondaryTitles: [String: [SecondaryTitle]]?

    @State private var isOpen = false

    private var others: [SeriesTitle.Alternative] {
        SeriesTitle.alternatives(
            in: Self.merging(
                romanizedTitle: romanizedTitle, nativeTitle: nativeTitle,
                secondaryTitles: secondaryTitles, into: titles, shown: shown
            ),
            excluding: shown
        )
    }

    /// `titles` plus whatever `romanizedTitle`/`nativeTitle`/`secondaryTitles`
    /// name that is not already in there — case-insensitively, since the
    /// record measured for this (series 2060, 2026-09-15) has its
    /// `native_title` and `romanized_title` both duplicating an existing
    /// `titles` entry verbatim, and every one of its `secondary_titles` also
    /// duplicating one. Nothing in that fixture actually adds a row; a
    /// series without that overlap is the case this guards for.
    nonisolated static func merging(
        romanizedTitle: String?, nativeTitle: String?,
        secondaryTitles: [String: [SecondaryTitle]]?,
        into titles: [SeriesTitle], shown: String?
    ) -> [SeriesTitle] {
        var merged = titles
        var seenLower = Set(titles.map { $0.title.lowercased() })
        if let shown { seenLower.insert(shown.lowercased()) }

        // The native title's own language, read off whichever existing entry
        // already carries the "native" trait — the same rule
        // `Series.nativeLanguage` uses, and excluding `-Latn` for the same
        // reason: that tag names a romanisation, not the native language.
        let nativeLanguage = titles.first {
            $0.traits.contains("native") && !$0.language.hasSuffix("-Latn")
        }?.language

        func add(_ title: String?, language: String, traits: [String]) {
            guard let title, !title.isEmpty, !seenLower.contains(title.lowercased()) else { return }
            merged.append(SeriesTitle(language: language, traits: traits, title: title, isPrimary: nil))
            seenLower.insert(title.lowercased())
        }

        // "native"/"romanized"/"alternative" as language tags are a guess for
        // the (rare, given the dedup above) case where none of the real
        // titles say what language these are in — `LanguageFlag` shows the
        // tag itself, upper-cased, for anything it does not recognise,
        // rather than drawing a wrong flag.
        add(nativeTitle, language: nativeLanguage ?? "native", traits: ["native"])
        add(romanizedTitle, language: nativeLanguage.map { "\($0)-Latn" } ?? "romanized", traits: [])
        for entry in (secondaryTitles ?? [:]).values.flatMap({ $0 }) {
            add(entry.title, language: entry.type ?? "alternative", traits: [])
        }
        return merged
    }

    var body: some View {
        let rows = others
        if !rows.isEmpty {
            Button { isOpen = true } label: {
                HStack(spacing: 5) {
                    Text("Also known as")
                        .typeSmallMeta()
                    Text("\(rows.count)")
                        .typeGridMeta()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Palette.surfaceChip, in: Capsule())
                    Image(systemName: "chevron.right")
                        .typeSymbol(size: 9, weight: .semibold)
                }
                .foregroundStyle(Palette.textMuted)
                .frame(minHeight: Metrics.tapTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .accessibilityLabel("Also known as, \(rows.count) other titles")
            .accessibilityHint("Opens the full list")
            .sheet(isPresented: $isOpen) {
                AlternativeTitlesSheet(rows: rows)
                    .presentationDetents([.medium, .large])
                    .presentationCornerRadius(Metrics.radiusSheet)
            }
        }
    }
}

/// Every other name, in the API's own order.
struct AlternativeTitlesSheet: View {
    let rows: [SeriesTitle.Alternative]

    @Environment(\.dismiss) private var dismiss
    /// Bumped per copy, for the haptic; see `Haptics`.
    @State private var copies = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        titleRow(row)
                        if row.id != rows.last?.id {
                            Rectangle()
                                .fill(Palette.hairline)
                                .frame(height: 0.5)
                                .padding(.leading, 14)
                        }
                    }
                }
                .background(Palette.surface, in: RoundedRectangle(
                    cornerRadius: Metrics.radiusCard, style: .continuous
                ))
                .hairlineBorder(Palette.border, radius: Metrics.radiusCard)
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Palette.ground)
            .navigationTitle("Also known as")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Palette.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .edgeSwipeToDismiss()
    }

    /// Each row copies its own title on tap.
    ///
    /// The reason to open this list at all is usually to take one of these
    /// somewhere else — a search, a message, a reading site — and holding a
    /// line of text to select it inside a scroll view is a fight.
    private func titleRow(_ row: SeriesTitle.Alternative) -> some View {
        Button {
            UIPasteboard.general.string = row.title
            copies += 1
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.title)
                    .typeBody()
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(row.languageLabel)
                    .typeGridMeta()
                    .foregroundStyle(Palette.textMuted)
                    .multilineTextAlignment(.trailing)
                // Last, in a fixed column, so the flags line up down the
                // list whatever the length of the name beside them.
                Text(row.flags)
                    .typeGridMeta()
                    .frame(minWidth: Metrics.flagColumn, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: Metrics.tapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .haptic(Haptics.copied, onEach: copies)
        .accessibilityLabel("\(row.title), \(row.languageLabel)")
        .accessibilityHint("Copies this title")
    }
}

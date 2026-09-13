import SwiftUI

/// Volumes with dates their publishers have actually announced.
///
/// The rest of the Schedule screen is inference — how often a series has
/// shipped before, turned into a guess. This is not a guess, and the screen has
/// to make that difference visible, because the whole value of the section is
/// that these dates can be relied on.
///
/// So: it leads, it is dated precisely rather than "about the 12th", and a
/// series appearing here is removed from the estimates below.
struct AnnouncedSection: View {
    let works: [UpcomingWork]
    /// Gap 97: fetching announced dates failing used to collapse into the
    /// same empty `works` a genuinely quiet week produces, so a reader
    /// offline saw "nothing announced" — the truth withheld rather than
    /// stated. Set, this renders as an inline failure with Retry instead of
    /// the section simply not appearing.
    var failure: APIError?
    var onRetry: (() async -> Void)?
    /// Opens the series a row names, given its id. Gap 101: a row used to be
    /// a dead tap — nothing here made it into a link at all. Defaulted so
    /// existing previews and any other call site keep compiling; `onOpen`
    /// receiving an id it cannot resolve is expected to no-op rather than
    /// this view guessing at a fallback destination.
    var onOpen: (Int) -> Void = { _ in }

    var body: some View {
        if !works.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                heading
                VStack(spacing: 8) {
                    ForEach(Array(works.enumerated()), id: \.element.id) { index, work in
                        row(work)
                            .arrives(index: index)
                    }
                }
            }
        } else if let failure {
            VStack(alignment: .leading, spacing: 12) {
                heading
                InlineFailure(error: failure, retry: onRetry)
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Announced")
            Text("""
            Dates the publishers have given. Everything below this is \
            an estimate; these are not.
            """)
            .typeSmallMeta()
            .foregroundStyle(Palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ work: UpcomingWork) -> some View {
        // Gap 101: the date-and-title half of the row opens the series (when
        // its id resolves to one); the publisher link stays its own,
        // separate tap target at the trailing edge rather than nested inside
        // the same control — a `Link` inside a `Button` fights it for the
        // gesture instead of adding a second one.
        HStack(alignment: .top, spacing: 12) {
            Button {
                guard let seriesId = work.seriesId else { return }
                onOpen(seriesId)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    dateBlock(work)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(work.title ?? "Untitled")
                            .typeRowTitle()
                            .foregroundStyle(Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = detail(work) {
                            Text(detail)
                                .typeSmallMeta()
                                .foregroundStyle(Palette.textMuted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .disabled(work.seriesId == nil)

            if let link = work.publisherLink {
                Link(destination: link) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Open the publisher's page")
            }
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(
            cornerRadius: Metrics.radiusCard, style: .continuous
        ))
        .hairlineBorder(Palette.border, radius: Metrics.radiusCard)
    }

    /// The date as a calendar block rather than a sentence.
    ///
    /// A column of "15 Sep" reads down the page as a calendar; a column of
    /// "arrives on 15 September" reads as prose that happens to contain dates.
    private func dateBlock(_ work: UpcomingWork) -> some View {
        VStack(spacing: 1) {
            Text(day(work))
                .typeStatNumber()
                .foregroundStyle(Palette.accent)
            Text(month(work))
                .typeEyebrow()
                .foregroundStyle(Palette.textMuted)
        }
        .frame(width: 42)
        .accessibilityElement(children: .combine)
    }

    private func day(_ work: UpcomingWork) -> String {
        guard let date = work.date else { return "–" }
        return Self.day.string(from: date)
    }

    private func month(_ work: UpcomingWork) -> String {
        guard let date = work.date else { return "" }
        return Self.month.string(from: date).uppercased()
    }

    /// "Vol. 11 · 228 pages", and only the parts the API supplied.
    private func detail(_ work: UpcomingWork) -> String? {
        var parts: [String] = []
        if let volume = work.volume { parts.append(volume) }
        if let pages = work.pages, pages > 0 { parts.append("\(pages) pages") }
        if let price = work.price, !price.isEmpty { parts.append(price) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let month: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

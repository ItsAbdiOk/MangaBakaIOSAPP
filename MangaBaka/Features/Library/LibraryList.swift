import SwiftUI

/// The library as one list, with the controls that make a thousand rows
/// navigable.
///
/// Replaces a screen of shelf cards. Cards answered "what states do I have?",
/// which is a question the shape bar now answers in seven points of height —
/// and they could not answer the question a reader with 1,204 entries actually
/// has, which is "where is that one".
struct LibraryList: View {
    @Bindable var model: LibraryModel
    @Binding var path: [Series]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            header
            ForEach(model.listed) { entry in
                row(entry)
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.filter?.title ?? "All series")
                .typeSubsectionHeader()
                .foregroundStyle(Palette.textPrimary)
            Spacer(minLength: 8)
            sortControl
        }
        .padding(.bottom, 12)
    }

    /// A menu, not a row of options. Four sorts inline would take a line of the
    /// screen permanently to answer a question asked once a month.
    private var sortControl: some View {
        Menu {
            Picker("Sort", selection: $model.sort) {
                ForEach(LibrarySort.allCases) { sort in
                    Text(sort.label).tag(sort)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.sort.label)
                    .typeInstruction()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Palette.accent)
            // 129x17 by Apple's measurement. The label keeps its size; the
            // menu's target does not have to be the same shape as its words.
            .frame(minHeight: Metrics.tapTarget)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Sort by \(model.sort.label)")
    }

    private func row(_ entry: LibraryEntry) -> some View {
        Button {
            if let series = entry.series { path.append(series) }
        } label: {
            HStack(spacing: 12) {
                if let series = entry.series {
                    CoverImage(
                        cover: series.cover,
                        width: 38,
                        radius: 5,
                        accessibilityText: series.displayTitle ?? "Cover art"
                    )
                } else {
                    // An entry whose series did not come back with it. Rare,
                    // and a blank of the right size keeps the row's rhythm
                    // rather than making one row a different height.
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Palette.surface)
                        .frame(width: 38, height: 38 / Metrics.coverAspect)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.series?.displayTitle ?? "Untitled series")
                        .typeRowTitle()
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        LibraryStateChip(state: entry.state)
                        if let progress = progressLine(entry) {
                            Text(progress)
                                .typeSmallMeta()
                                .foregroundStyle(Palette.textMuted)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                rating(entry)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        // The series, not its letter. Keying rows on the letter gave every row
        // beginning with the same letter the same SwiftUI identity, so the list
        // reused one row's view for another's data — rows showed the wrong
        // state chip, and under a title sort the stack left a screen-high gap
        // where it had collapsed identities together.
        .id(entry.seriesId)
    }

    /// "Ch 112 / 179", and only where progress means something.
    ///
    /// A plan-to-read entry showing "chapter 0 of 200" is noise about something
    /// nobody has started.
    private func progressLine(_ entry: LibraryEntry) -> String? {
        guard entry.state.tracksProgress else { return nil }
        if let volume = entry.progressVolume, volume > 0 {
            let total = entry.series?.finalVolume.map { " / \(Int($0))" } ?? ""
            return "Vol \(Int(volume))\(total)"
        }
        guard let chapter = entry.progressChapter, chapter > 0 else { return nil }
        let total = entry.series?.totalChapters.map { " / \(Int($0))" } ?? ""
        return "Ch \(Int(chapter))\(total)"
    }

    /// One star and a number, not five stars.
    ///
    /// Five glyphs per row down a thousand rows is five thousand glyphs saying
    /// what one number says. The edit sheet is where five stars belong, because
    /// that is where you set it.
    @ViewBuilder
    private func rating(_ entry: LibraryEntry) -> some View {
        if let rating = entry.rating, rating > 0 {
            HStack(spacing: 3) {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.accent)
                Text("\(Int((rating / 20).rounded()))")
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textSecondary)
            }
            .accessibilityLabel("Rated \(Int((rating / 20).rounded())) out of 5")
        } else {
            // Nothing at all, rather than a dash.
            //
            // On the device an unrated row ended in an em dash at
            // `textQuaternary` — 2.52:1 on this ground, so barely visible, and
            // meaningless on its own even when it was seen. A reader does not
            // need to be told that the space where a rating would be is empty.
            EmptyView()
        }
    }
}

/// The A-Z rail down the right edge.
///
/// Only ever shown sorted by title and past two hundred entries — an A-Z rail
/// down a list ordered by date points at nothing, and on forty entries it is
/// slower than scrolling.
///
/// It sits on the SCREEN, not on the list. Overlaid on the list it was
/// positioned against a stack thousands of points tall, so it centred itself
/// somewhere far below the fold and was never once seen.
struct JumpIndex: View {
    let targets: [(letter: String, id: Int)]
    let onJump: (Int) -> Void

    var body: some View {
        VStack(spacing: 1) {
            ForEach(targets, id: \.letter) { target in
                Button { onJump(target.id) } label: {
                    Text(target.letter)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary)
                        .frame(width: 20, height: 13)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.trailing, 3)
        .accessibilityLabel("Jump to a letter")
    }
}

/// The state filter, and the count beside each state.
struct LibraryFilterRow: View {
    let shape: [(state: LibraryEntry.State, count: Int)]
    let total: Int
    @Binding var selected: LibraryEntry.State?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                pill("All", count: total, isOn: selected == nil) { selected = nil }
                ForEach(shape, id: \.state) { band in
                    pill(band.state.title, count: band.count, isOn: selected == band.state) {
                        selected = selected == band.state ? nil : band.state
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter)
        }
        .scrollIndicators(.hidden)
    }

    private func pill(
        _ title: String,
        count: Int,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).typeChip()
                Text(count.formatted())
                    .typeChip()
                    .foregroundStyle(isOn ? Palette.onAccent.opacity(0.7) : Palette.textMuted)
            }
            .foregroundStyle(isOn ? Palette.onAccent : Palette.textSecondary)
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(isOn ? Palette.accent : Palette.surfaceChip, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) series")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

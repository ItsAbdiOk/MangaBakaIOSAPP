import SwiftUI

/// The shape of a library, as one proportional bar.
///
/// A thousand entries is a number nobody can picture. Five bands in proportion
/// answer "how much of this have I actually finished?" without a single figure,
/// and the same bands are the filter a reader wants anyway — so tapping one is
/// the fastest route into a state.
struct LibraryShapeBar: View {
    let counts: [(state: LibraryEntry.State, count: Int)]
    @Binding var selected: LibraryEntry.State?

    private var total: Int { counts.reduce(0) { $0 + $1.count } }

    var body: some View {
        if total > 0 {
            VStack(alignment: .leading, spacing: 0) {
                bar
                legend
            }
        }
    }

    /// The bar is 7pt tall and its bands are the fastest way into a state, so
    /// the row it lives in is 44pt and the bands are tapped through it. Apple's
    /// audit named the bar by its full label — "Reading 71, Rereading 1, …" —
    /// as a hit area of 370x7.
    private var bar: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(counts, id: \.state) { band in
                    Capsule()
                        .fill(Self.colour(band.state))
                        // Dimmed rather than hidden when another band is
                        // filtered: the bar is the shape of the whole library,
                        // and removing the rest would make it the shape of the
                        // filter instead.
                        .opacity(selected == nil || selected == band.state ? 1 : 0.28)
                        .frame(width: width(band.count, in: proxy.size.width), height: Metrics.shapeBar)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Motion.run(.snappy(duration: 0.2)) {
                                selected = selected == band.state ? nil : band.state
                            }
                        }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: Metrics.tapTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Bands narrower than this vanish, and a band you cannot tap is not a
    /// filter. Two entries in a library of twelve hundred still get something
    /// to aim at.
    private func width(_ count: Int, in available: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        let gaps = CGFloat(max(counts.count - 1, 0)) * 2
        let usable = max(available - gaps, 0)
        return max(4, usable * CGFloat(count) / CGFloat(total))
    }

    /// `lineSpacing: 0` because each row is now a full 44pt tap target and
    /// carries its own room; the old 12pt gap on top of that would push the
    /// first shelf off the screen.
    private var legend: some View {
        FlowLayout(spacing: 12, lineSpacing: 0) {
            ForEach(counts, id: \.state) { band in
                Button {
                    Motion.run(.snappy(duration: 0.2)) {
                        selected = selected == band.state ? nil : band.state
                    }
                } label: {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Self.colour(band.state))
                            .frame(width: 7, height: 7)
                        Text(band.state.title)
                            .typeFootnote()
                            .foregroundStyle(
                                selected == band.state ? Palette.textPrimary : Palette.textTertiary
                            )
                    }
                    .frame(minHeight: Metrics.tapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.press)
                .accessibilityLabel("\(band.state.title), \(band.count) series")
            }
        }
    }

    private var accessibilityLabel: String {
        counts
            .map { "\($0.state.title) \($0.count)" }
            .joined(separator: ", ")
    }

    /// One colour per state, and they are the same colours the state chips use.
    ///
    /// Reading takes the accent because it is the state a reader is actually
    /// in. Dropped is barely a colour at all — it is counted, not celebrated.
    static func colour(_ state: LibraryEntry.State) -> Color {
        switch state {
        case .reading, .rereading: Palette.accent
        case .paused: Palette.paused
        case .completed: Palette.positive
        case .planToRead, .considering: Palette.textTertiary
        case .dropped: Palette.borderPill
        }
    }
}

/// The small all-caps pill on a library row.
struct LibraryStateChip: View {
    let state: LibraryEntry.State

    var body: some View {
        Text(state.title.uppercased())
            .typeEyebrow()
            .foregroundStyle(LibraryShapeBar.colour(state))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            // A tint of the state's own colour rather than the colour itself:
            // six saturated pills down a list of a thousand rows is a barcode.
            .background(LibraryShapeBar.colour(state).opacity(0.16), in: Capsule())
    }
}

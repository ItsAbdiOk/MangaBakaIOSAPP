import SwiftUI

/// When the next chapter of each series you are reading is likely due.
///
/// The honesty is the design. No source publishes real manga schedules, so
/// every date here is inferred from past release gaps, and the copy says
/// "likely" or "loose" rather than printing a date and letting it look settled.
struct ScheduleView: View {
    @State private var model: ScheduleModel
    @Binding private var path: [Series]

    init(model: ScheduleModel, path: Binding<[Series]>) {
        _model = State(initialValue: model)
        _path = path
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                // Announced dates lead, and appear even when there is nothing
                // to estimate from: a reader with no measurable series can
                // still have a volume arriving on Tuesday.
                AnnouncedSection(works: model.announced)
                    .padding(.bottom, model.announced.isEmpty ? 0 : 26)

                if let failure = model.libraryFailure, model.announced.isEmpty {
                    FailureState(error: failure, retry: { await model.load() })
                        .padding(.top, 60)
                } else if model.libraryFailure != nil {
                    EmptyView()
                } else if model.isEmpty && model.announced.isEmpty {
                    emptyState
                } else if model.isEmpty {
                    EmptyView()
                } else {
                    controls
                    if model.isMeasuring { measuringCard }
                    if model.isStale { staleCard }
                    // The scope card counts estimates. Before the first
                    // measurement there are none, and "0 estimated of 0 in
                    // scope" over two thirds of an empty screen is what the
                    // device review found. Say what Measure will do instead.
                    if model.hasNeverMeasured {
                        firstRunCard
                    } else {
                        scopeCard
                        ForEach(model.groups) { group in
                            groupSection(group)
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.scrollTopInset)
            .padding(.bottom, Metrics.scrollBottomInset)
        }
        .scrollIndicators(.hidden)
        .background(Palette.ground)
        .task { await model.load() }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Next chapters")
                .typeScreenTitle()
                .foregroundStyle(Palette.textEmphasis)
            Text("""
            Estimated from how often each series has actually shipped. No \
            publisher schedules exist, so nothing here is a fact.
            """)
            .typeSubtitle()
            .foregroundStyle(Palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Text(model.measuredLine)
                .typeSmallMeta()
                .foregroundStyle(model.isStale ? Palette.accent : Palette.textMuted)
            Spacer(minLength: 0)
            Button {
                Task { await model.measure(refresh: model.snapshot.measuredAt != nil) }
            } label: {
                Text(model.remeasureLabel)
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Palette.surfacePill, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.borderPill, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(model.isMeasuring)
        }
        .padding(.top, 16)
        .padding(.horizontal, 2)
    }

    /// A build takes minutes and can be interrupted by the phone locking, so
    /// the card says plainly that progress survives.
    private var measuringCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.measuringLine)
                    .typeRowTitle()
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 10)
                Text("\(max(model.progress.total - model.progress.done, 0)) left")
                    .typeSmallMeta()
                    .foregroundStyle(Palette.textMuted)
            }
            ProgressView(value: model.progress.fraction)
                .tint(Palette.accent)
                .padding(.top, 10)
            Text("""
            Results appear as they land. Leaving the screen does not lose \
            progress — it resumes where it stopped.
            """)
            .typeFootnote()
            .foregroundStyle(Palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 9)
        }
        .padding(14)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .hairlineBorder(Palette.border, radius: 15)
        .padding(.top, 14)
    }

    private var staleCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("These estimates have drifted")
                .typeRowTitle()
                .foregroundStyle(Palette.textPrimary)
            Text("""
            \(model.snapshot.stale) were measured more than a fortnight ago, so \
            their gaps are probably out of date.
            """)
            .typeChip()
            .foregroundStyle(Palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .hairlineBorder(Palette.border, radius: 15)
        .padding(.top, 14)
    }

    /// What the first measurement is about to do, and how long it will take.
    private var firstRunCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "Nothing measured yet")
            Text(model.firstRunExplanation)
                .typeFootnote()
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 13)
            Button {
                Task { await model.measure(refresh: false) }
            } label: {
                Text("Measure now")
                    .typeCTA()
                    .foregroundStyle(Palette.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.ctaSecondary)
                    .background(Palette.accent, in: RoundedRectangle(
                        cornerRadius: Metrics.radiusCard, style: .continuous
                    ))
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .hairlineBorder(Palette.border, radius: 18)
        .padding(.top, 20)
    }

    /// The count, and the reason confidence and lateness are shown separately.
    private var scopeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: model.scopeLine)
            Text("""
            Confidence and lateness are measured separately. A series can ship \
            like clockwork and still be a year overdue — that pairing is the \
            useful part.
            """)
            .typeFootnote()
            .foregroundStyle(Palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 13)
            if let failure = model.measurementFailureLine {
                Text(failure)
                    .typeFootnote()
                    .foregroundStyle(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 9)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .hairlineBorder(Palette.border, radius: 18)
        .padding(.top, 20)
    }

    private func groupSection(_ group: ScheduleModel.Group) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(group.title)
                    .typeSectionHeader()
                    .foregroundStyle(group.isOverdue ? Palette.accent : Palette.textPrimary)
                Text(group.count)
                    .typeChip()
                    .foregroundStyle(Palette.textMuted)
            }
            Text(group.blurb)
                .typeSmallMeta()
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            VStack(spacing: 0) {
                ForEach(group.works) { work in
                    ScheduleRow(work: work) { path.append(work.series) }
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 2)
        .padding(.top, Metrics.sectionGap)
    }

    private var emptyState: some View {
        // DRAFT COPY (Claude, 2026-09-10). The design board left this one
        // undrawn and said the sentence needs Abdi's wording more than its
        // layout — it has to explain a rule the reader never set. Flagged to
        // him; replace this rather than adding to it.
        EmptyState(
            title: "Nothing to predict yet",
            message: """
            Predictions are built from series you are reading, rereading or \
            have paused. Completed and dropped series are left alone on \
            purpose — there is no next chapter to wait for.
            """
        )
    }
}

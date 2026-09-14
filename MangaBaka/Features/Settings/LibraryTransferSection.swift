import SwiftUI
import UniformTypeIdentifiers

/// Drives the export/import section: loads the library once for export, picks
/// a file, parses it, previews what it would do, and applies it.
///
/// A plain `@Observable` object rather than view `@State` scattered across
/// several properties, for the same reason `RetryGate` and
/// `LibraryImportProgress` are: the parse-then-preview logic is worth testing
/// without a `Settings` screen on the other end of it.
@MainActor
@Observable
final class LibraryTransferModel {
    private let library: any LibraryProviding
    /// Optional on purpose: nil means the walk failed or was page-capped,
    /// which is not the same answer as "your library is empty". Importing
    /// against the wrong one of those rewrites the reader's real account --
    /// `LibraryImport`'s "never downgrade progress" guard compares against
    /// this set, so an empty one turns every row into an add and walks their
    /// own progress backwards, one request per row (review 2, item 4).
    private let loadExisting: () async -> [LibraryEntry]?

    private(set) var entries: [LibraryEntry] = []
    var isPickingFile = false
    var isShowingPreview = false
    var parseFailureMessage: String?

    private(set) var preview: [ImportedEntry] = []
    private(set) var previewCounts: PreviewCounts?
    let progress = LibraryImportProgress()
    var isApplying = false
    private(set) var lastReport: ImportReport?

    struct PreviewCounts: Equatable {
        var new = 0
        var updates = 0
        var skipped = 0
        var unresolved = 0

        var total: Int { new + updates + skipped + unresolved }

        /// "312 entries: 40 new, 270 updates, 2 skipped" — the mockup's exact
        /// wording, with the unresolved-MAL clause only appearing when it
        /// applies rather than always reading "0 need a match".
        var summary: String {
            var parts = ["\(new) new", "\(updates) update\(updates == 1 ? "" : "s")"]
            if skipped > 0 { parts.append("\(skipped) skipped") }
            if unresolved > 0 { parts.append("\(unresolved) need a MangaBaka match — not built") }
            return "\(total) entries: " + parts.joined(separator: ", ")
        }
    }

    init(library: any LibraryProviding, loadExisting: @escaping () async -> [LibraryEntry]?) {
        self.library = library
        self.loadExisting = loadExisting
    }

    /// The two export payloads, encoded once when the entries are loaded.
    ///
    /// Item 105: `jsonExportItem()` and `csvExportItem()` were called from
    /// inside `body`, so both re-encoded all 939 entries on every render of
    /// the Settings screen — a JSON encode and a CSV build per toast, per
    /// scroll, per anything. They change exactly when `entries` does.
    private(set) var jsonFile: LibraryExportJSONFile?
    private(set) var csvFile: LibraryExportCSVFile?

    /// Whether the export payloads are ready to share.
    var isExportReady: Bool { jsonFile != nil }

    /// Whether `entries` is the reader's whole library rather than a default.
    /// An empty library is a legitimate answer; not having read it is not.
    private(set) var knowsTheLibrary = false

    /// Nil from `loadExisting` leaves `knowsTheLibrary` false, which is what
    /// refuses the import below.
    func loadEntriesIfNeeded() async {
        guard !knowsTheLibrary else { return }
        guard let existing = await loadExisting() else { return }
        entries = existing
        knowsTheLibrary = true
        encodeExports()
    }

    private func encodeExports() {
        guard !entries.isEmpty else {
            jsonFile = nil
            csvFile = nil
            return
        }
        let stem = LibraryExport.filenameStem()
        jsonFile = LibraryExportJSONFile(data: LibraryExport.json(entries), filename: "\(stem).json")
        csvFile = LibraryExportCSVFile(data: LibraryExport.csv(entries), filename: "\(stem).csv")
    }

    func handlePicked(_ result: Result<URL, any Error>) async {
        parseFailureMessage = nil
        guard case let .success(url) = result else { return }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        // Off the main actor: a MyAnimeList XML export is megabytes, and
        // reading it here hitched the sheet that is still on screen (item
        // 105). The security-scoped access above is held for the duration by
        // the `defer`, so the detached read is inside it.
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url)
        }.value
        guard let data else {
            parseFailureMessage = "Couldn't read that file."
            return
        }

        await loadEntriesIfNeeded()
        guard knowsTheLibrary else {
            parseFailureMessage = "Couldn't read your library just now, so importing"
                + " could overwrite what is already there. Try again in a moment."
            return
        }

        switch LibraryImport.parse(data) {
        case let .success(parsed):
            preview = parsed
            previewCounts = Self.count(parsed, against: entries)
            isShowingPreview = true
        case .failure(.invalidFormat):
            parseFailureMessage = "That didn't look like a MangaBaka export or a MyAnimeList file."
        case .failure(.empty):
            parseFailureMessage = "That file didn't name any entries."
        }
    }

    /// `nonisolated static` so the preview arithmetic can be tested without
    /// a Settings screen or a main-actor hop — see work-list 17's test.
    nonisolated static func count(
        _ parsed: [ImportedEntry], against existing: [LibraryEntry]
    ) -> PreviewCounts {
        // `uniquingKeysWith:`, not `uniqueKeysWithValues:` (item 17): the
        // library walk appends pages with no dedupe of its own, and a series
        // that moves between pages while the walk is running arrives twice —
        // which trapped here, in Settings, on the reader's own library.
        // First wins, matching the walk's own rule.
        let existingBySeries = Dictionary(
            existing.map { ($0.seriesId, $0) }, uniquingKeysWith: { first, _ in first }
        )
        var counts = PreviewCounts()
        for entry in parsed {
            guard let seriesId = entry.seriesId else {
                counts.unresolved += 1
                continue
            }
            guard let current = existingBySeries[seriesId] else {
                counts.new += 1
                continue
            }
            if let currentChapter = current.progressChapter,
               let importedChapter = entry.progressChapter, importedChapter < currentChapter {
                counts.skipped += 1
            } else {
                counts.updates += 1
            }
        }
        return counts
    }

    /// Runs the import, cancellable through `progress.cancel()`.
    func confirmApply() async -> ImportReport {
        isApplying = true
        let report = await LibraryImport.apply(preview, to: library, existing: entries, progress: progress)
        isApplying = false
        lastReport = report
        // The cached list is now behind whatever was just written; the next
        // export or import in this session should see the real thing.
        entries = []
        encodeExports()
        return report
    }
}

/// Export and import of the reader's own library — a safety net independent
/// of MangaBaka staying reachable, or the app staying installed.
struct LibraryTransferSection: View {
    @State private var model: LibraryTransferModel
    @Environment(ToastCentre.self) private var toasts: ToastCentre?

    /// Which export the share sheet is currently up for, if either.
    @State private var sharing: Export?

    /// `Identifiable` so `.sheet(item:)` can carry it; the payload itself
    /// lives on the model, encoded once.
    enum Export: String, Identifiable {
        case json, csv
        var id: String { rawValue }
    }

    /// Both of these come from `AppServices` now, through `SettingsView`
    /// (item 20).
    ///
    /// They used to default to a standalone `LibraryService` and an
    /// unshared, uncached `LibrarySnapshot`, walked from `.task` on every
    /// appearance — ~13 requests and ~25 MB for an export nobody had tapped,
    /// on a screen that looks like a settings page. No defaults now, so the
    /// wasteful stand-in cannot come back by omission.
    init(library: any LibraryProviding, loadExisting: @escaping () async -> [LibraryEntry]?) {
        _model = State(initialValue: LibraryTransferModel(library: library, loadExisting: loadExisting))
    }

    var body: some View {
        SettingsSection(title: "Library backup", caption: caption) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsCard {
                    exportRow
                    SettingsDivider()
                    csvExportRow
                    SettingsDivider()
                    importRow
                }
                if let parseFailureMessage = model.parseFailureMessage {
                    Text(parseFailureMessage)
                        .typeSmallMeta()
                        .foregroundStyle(Palette.accent)
                }
            }
        }
        // No `.task { await model.loadEntriesIfNeeded() }` here (item 20):
        // the export rows load on tap, and the import path loads inside
        // `handlePicked` where it is genuinely needed to count the preview.
        .fileImporter(
            isPresented: $model.isPickingFile,
            allowedContentTypes: [.json, .commaSeparatedText, .xml],
            onCompletion: { result in Task { await model.handlePicked(result) } }
        )
        .sheet(isPresented: $model.isShowingPreview) {
            LibraryImportPreviewSheet(model: model, toasts: toasts)
        }
        .sheet(item: $sharing) { export in
            LibraryExportShareSheet(model: model, export: export)
        }
    }

    private var caption: String {
        "A copy of your library you keep yourself — export it as a file, or bring one back in."
    }

    private var exportRow: some View { exportRow(.json, title: "Export as JSON", name: "JSON") }

    private var csvExportRow: some View { exportRow(.csv, title: "Export as CSV", name: "CSV") }

    /// A tap is what fetches the library, not an appearance (item 20). The
    /// share sheet opens once the entries are in hand; until then the row
    /// shows the spinner the two `ShareLink`s used to show while a walk
    /// nobody asked for ran behind them.
    private func exportRow(_ export: Export, title: String, name: String) -> some View {
        Button {
            Task {
                await model.loadEntriesIfNeeded()
                guard model.isExportReady else { return }
                sharing = export
            }
        } label: {
            SettingsRow(title: title, caption: nil) {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(Palette.accent)
            }
        }
        .buttonStyle(.press)
        .accessibilityLabel("Export library as \(name)")
    }

    private var importRow: some View {
        Button {
            model.parseFailureMessage = nil
            model.isPickingFile = true
        } label: {
            SettingsRow(
                title: "Import…",
                caption: "A MangaBaka export, or a MyAnimeList XML file."
            ) {
                Image(systemName: "square.and.arrow.down")
                    .foregroundStyle(Palette.accent)
            }
        }
        .buttonStyle(.press)
    }
}

/// What the reader sees before an import touches their real account: the
/// count, then a destructive confirmation naming exactly what it does.
private struct LibraryImportPreviewSheet: View {
    @Bindable var model: LibraryTransferModel
    let toasts: ToastCentre?

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirming = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                if model.isApplying {
                    applyingBody
                } else {
                    previewBody
                }
            }
            .padding(Metrics.gutter)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Palette.ground)
            .navigationTitle("Import preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .confirmDestructive(
            isPresented: $isConfirming,
            title: "Import into your MangaBaka library?",
            consequence: "This writes to your real MangaBaka account — the same "
                + "library the app shows everywhere else: \(summary). "
                + "Progress already ahead of a row is never moved backwards.",
            label: "Import"
        ) {
            let report = await model.confirmApply()
            toasts?.show(toastMessage(for: report), kind: report.failures > 0 ? .failure : .success)
            dismiss()
        }
    }

    private var summary: String {
        model.previewCounts?.summary ?? "\(model.preview.count) entries"
    }

    private var previewBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(summary)
                .typeSubsectionHeader()
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                "This changes your MangaBaka account, not just this phone. "
                    + "Nothing is sent until you confirm."
            )
            .typeSmallMeta()
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            Button("Import") { isConfirming = true }
                .buttonStyle(.press)
                .disabled(model.preview.isEmpty)
        }
    }

    private var applyingBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(
                value: Double(model.progress.completed),
                total: Double(max(model.progress.total, 1))
            )
            Text("\(model.progress.completed) of \(model.progress.total)")
                .typeSmallMeta()
                .foregroundStyle(Palette.textSecondary)
            Button("Stop") { model.progress.cancel() }
                .buttonStyle(.press)
        }
    }

    private func toastMessage(for report: ImportReport) -> String {
        guard report.failures == 0 else {
            return "Imported with \(report.failures) failure\(report.failures == 1 ? "" : "s")"
        }
        return "Imported \(report.added) new, updated \(report.updated)"
    }
}

/// The share sheet an export row opens, holding the `ShareLink` that used to
/// sit in the row itself.
///
/// A `ShareLink` needs its payload at the moment it is *built*, which is why
/// the row version forced a whole library walk on appearance (item 20). Here
/// the payload already exists by the time this view is presented.
private struct LibraryExportShareSheet: View {
    let model: LibraryTransferModel
    let export: LibraryTransferSection.Export

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            switch export {
            case .json:
                if let file = model.jsonFile {
                    link(item: file, filename: file.filename)
                }
            case .csv:
                if let file = model.csvFile {
                    link(item: file, filename: file.filename)
                }
            }
            Button("Done") { dismiss() }
                .buttonStyle(.press)
        }
        .padding(Metrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Palette.ground)
        .presentationDetents([.height(200)])
    }

    private func link(item: some Transferable, filename: String) -> some View {
        ShareLink(item: item, preview: SharePreview(filename)) {
            Label("Share \(filename)", systemImage: "square.and.arrow.up")
                .typeCTA()
                .foregroundStyle(Palette.accent)
        }
    }
}

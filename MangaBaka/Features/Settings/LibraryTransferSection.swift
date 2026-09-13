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
    private let loadExisting: () async -> [LibraryEntry]

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

    init(library: any LibraryProviding, loadExisting: @escaping () async -> [LibraryEntry]) {
        self.library = library
        self.loadExisting = loadExisting
    }

    func loadEntriesIfNeeded() async {
        guard entries.isEmpty else { return }
        entries = await loadExisting()
    }

    func jsonExportItem() -> LibraryExportJSONFile? {
        guard !entries.isEmpty else { return nil }
        return LibraryExportJSONFile(
            data: LibraryExport.json(entries),
            filename: "\(LibraryExport.filenameStem()).json"
        )
    }

    func csvExportItem() -> LibraryExportCSVFile? {
        guard !entries.isEmpty else { return nil }
        return LibraryExportCSVFile(
            data: LibraryExport.csv(entries),
            filename: "\(LibraryExport.filenameStem()).csv"
        )
    }

    func handlePicked(_ result: Result<URL, any Error>) async {
        parseFailureMessage = nil
        guard case let .success(url) = result else { return }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            parseFailureMessage = "Couldn't read that file."
            return
        }

        await loadEntriesIfNeeded()

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

    private static func count(_ parsed: [ImportedEntry], against existing: [LibraryEntry]) -> PreviewCounts {
        let existingBySeries = Dictionary(uniqueKeysWithValues: existing.map { ($0.seriesId, $0) })
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
        return report
    }
}

/// Export and import of the reader's own library — a safety net independent
/// of MangaBaka staying reachable, or the app staying installed.
struct LibraryTransferSection: View {
    @State private var model: LibraryTransferModel
    @Environment(ToastCentre.self) private var toasts: ToastCentre?

    /// `library`/`loadExisting` default to a standalone `LibraryService` and
    /// an unshared, uncached `LibrarySnapshot` walk — a working but wasteful
    /// stand-in (a second full walk of the library alongside whatever
    /// `AppServices.librarySnapshot` already did for this session).
    /// `AppServices` already owns a `LibraryService` and that shared,
    /// caching snapshot; wiring those in instead needs `SettingsView` to
    /// accept and thread `library`/`librarySnapshot` through, which is out
    /// of scope here — see the report for the exact call.
    init(
        library: any LibraryProviding = LibraryTransferSection.defaultLibrary,
        loadExisting: (() async -> [LibraryEntry])? = nil
    ) {
        let resolvedLoad = loadExisting ?? { await LibrarySnapshot(library: library).all() }
        _model = State(initialValue: LibraryTransferModel(library: library, loadExisting: resolvedLoad))
    }

    static var defaultLibrary: LibraryService {
        LibraryService(client: APIClient(
            baseURL: Self.defaultBaseURL,
            tokenProvider: ResolvingTokenProvider(infoDictionary: Bundle.main.infoDictionary)
        ))
    }

    /// Mirrors `AppServices.makeClient`'s own fallback: a hard-coded literal
    /// known to parse at compile time, unwrapped honestly rather than with
    /// `!` (`AppServices`' own helper for this is `private` to that file).
    private static var defaultBaseURL: URL {
        guard let url = URL(string: "https://api.mangabaka.org") else {
            preconditionFailure("Hard-coded base URL literal failed to parse.")
        }
        return url
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
        .task { await model.loadEntriesIfNeeded() }
        .fileImporter(
            isPresented: $model.isPickingFile,
            allowedContentTypes: [.json, .commaSeparatedText, .xml],
            onCompletion: { result in Task { await model.handlePicked(result) } }
        )
        .sheet(isPresented: $model.isShowingPreview) {
            LibraryImportPreviewSheet(model: model, toasts: toasts)
        }
    }

    private var caption: String {
        "A copy of your library you keep yourself — export it as a file, or bring one back in."
    }

    private var exportRow: some View {
        SettingsRow(title: "Export as JSON", caption: nil) {
            if let item = model.jsonExportItem() {
                ShareLink(item: item, preview: SharePreview(item.filename)) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(Palette.accent)
                }
                .accessibilityLabel("Export library as JSON")
            } else {
                ProgressView().tint(Palette.textTertiary)
            }
        }
    }

    private var csvExportRow: some View {
        SettingsRow(title: "Export as CSV", caption: nil) {
            if let item = model.csvExportItem() {
                ShareLink(item: item, preview: SharePreview(item.filename)) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(Palette.accent)
                }
                .accessibilityLabel("Export library as CSV")
            } else {
                ProgressView().tint(Palette.textTertiary)
            }
        }
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

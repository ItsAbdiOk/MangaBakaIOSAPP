import AVFoundation
import SwiftUI
import VisionKit

/// Point the camera at a book's barcode; if it is on this series' shelf, tick
/// it.
///
/// Scoped to the series page it was opened from, on purpose: the only rows it
/// can match are the ones already on screen, so a barcode that is not among
/// them says "not on this series' shelf" and nothing else. No lookup, no
/// network — a scan that asked a catalogue would be a new request against a
/// host the reader was not told about, and the shelf above already asked
/// every catalogue the app knows.
///
/// **Every reason the camera cannot be used gets a sentence, in order:**
///
/// 1. The device has no scanner (`isSupported`) — every simulator, and any
///    iPhone without a Neural Engine. This is the line the dispatcher will
///    see when walking it.
/// 2. The scanner is supported but not available right now (`isAvailable`)
///    — the camera is restricted by a profile, or in use.
/// 3. Camera permission not yet asked → ask, once, here.
/// 4. Permission denied or restricted → say so and point at Settings.
///
/// None of these is a crash: nothing touches the camera until the answer to
/// all four is yes.
struct ISBNScanSheet: View {
    let shelves: [EditionShelf]
    let seriesID: Int
    let owned: Set<OwnedVolumeKey>
    /// The page's `toggleOwned`, so a scan and a tap go through one write.
    let toggle: (EditionVolume) -> Void

    /// Where the camera stands. `checking` only until `.task` has answered,
    /// which is synchronous for everything but the permission prompt.
    enum Stage: Equatable {
        case checking
        case unsupported
        case unavailable
        case denied
        case couldNotStart
        case scanning
    }

    /// What the last barcode came to.
    enum Outcome: Equatable {
        case matched(title: String, number: Int?, nowOwned: Bool)
        case notOnShelf(isbn: String)
        case notAnISBN(payload: String)
    }

    @State private var stage: Stage = .checking
    @State private var outcome: Outcome?
    /// The last payload acted on. The scanner reports a barcode again every
    /// time it re-enters the frame, and a reader steadying a book would
    /// otherwise tick and untick it once a second. A different barcode
    /// resets this, so scanning two books alternately still works.
    @State private var lastPayload: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let outcome {
                    outcomeLine(outcome)
                }
            }
            .background(Palette.ground)
            .navigationTitle("Scan a barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Palette.accent)
                }
            }
            .task { await prepare() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .checking:
            ProgressView().tint(Palette.textTertiary)
        case .scanning:
            ISBNScannerView(onRead: read, onCouldNotStart: { _ in stage = .couldNotStart })
        case .unsupported, .unavailable, .denied, .couldNotStart:
            Text(Self.wording(stage))
                .typeSmallMeta()
                .foregroundStyle(Palette.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metrics.gutterStack)
        }
    }

    /// One sentence per way the camera cannot be used — see the type's doc
    /// comment for the order they are checked in.
    nonisolated static func wording(_ stage: Stage) -> String {
        switch stage {
        case .unsupported: "Scanning needs a camera and this device has none."
        case .unavailable: "The camera can't be used right now."
        case .denied: "Camera access is off for MangaBaka. You can turn it on in Settings."
        case .couldNotStart: "The camera couldn't be started."
        case .checking, .scanning: ""
        }
    }

    private func outcomeLine(_ outcome: Outcome) -> some View {
        Text(Self.outcomeWording(outcome))
            .typeSmallMeta()
            .foregroundStyle(Palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 12)
            .background(Palette.surface)
            .accessibilityAddTraits(.updatesFrequently)
    }

    /// "Vol. 7 · now owned", "Not on this series' shelf — ISBN 978…", or why
    /// the barcode was not a book's.
    nonisolated static func outcomeWording(_ outcome: Outcome) -> String {
        switch outcome {
        case let .matched(title, number, nowOwned):
            let name = number.map { "Vol. \($0)" } ?? title
            return nowOwned ? "\(name) · now owned" : "\(name) · no longer owned"
        case let .notOnShelf(isbn):
            return "Not on this series' shelf — ISBN \(isbn)"
        case let .notAnISBN(payload):
            // A book's EAN-13 always starts 978 or 979; any other EAN-13 is
            // the retailer's sticker or a magazine. Say what was read so the
            // reader can see it was not the barcode they meant.
            return "That barcode isn't an ISBN — read \(payload)"
        }
    }

    // MARK: - The camera

    /// The four checks, in the order the type's doc comment lists them.
    private func prepare() async {
        guard DataScannerViewController.isSupported else {
            stage = .unsupported
            return
        }
        guard DataScannerViewController.isAvailable else {
            stage = .unavailable
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            stage = .scanning
        case .notDetermined:
            // The system prompt, shown once. Its copy is
            // `NSCameraUsageDescription` in `project.yml`.
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            stage = granted ? .scanning : .denied
        case .denied, .restricted:
            stage = .denied
        @unknown default:
            stage = .denied
        }
    }

    /// One barcode, validated, matched, and acted on — see `ISBN13`.
    private func read(_ payload: String) {
        guard payload != lastPayload else { return }
        lastPayload = payload
        guard let isbn = ISBN13.normalise(payload) else {
            outcome = .notAnISBN(payload: payload)
            return
        }
        guard let volume = ISBN13.match(isbn, in: shelves) else {
            outcome = .notOnShelf(isbn: isbn)
            return
        }
        let key = OwnedVolumeKey(seriesID: seriesID, volume: volume)
        let nowOwned = !owned.contains(key)
        toggle(volume)
        outcome = .matched(title: volume.title, number: volume.number, nowOwned: nowOwned)
    }
}

import SwiftUI
import Vision
import VisionKit

/// The arithmetic behind a barcode read: is it an ISBN-13, and which row of
/// this series' shelf is it.
///
/// Pure and `nonisolated static`, like `VolumeEditions`' helpers, so every
/// rule is tested without a camera — the simulator has none.
enum ISBN13 {
    /// The ISBN-13 check digit, per ISO 2108: weights 1,3,1,3,… over the
    /// first twelve digits, and the thirteenth makes the sum a multiple of
    /// ten. An EAN-13 barcode on a book *is* its ISBN-13 (the `978`/`979`
    /// "Bookland" prefixes), so the same check applies to the scan.
    nonisolated static func isValidISBN13(_ digits: String) -> Bool {
        guard digits.count == 13, digits.allSatisfy(\.isNumber) else { return false }
        let values = digits.compactMap(\.wholeNumberValue)
        guard values.count == 13 else { return false }
        let sum = values.enumerated().reduce(0) { total, pair in
            total + pair.element * (pair.offset.isMultiple(of: 2) ? 1 : 3)
        }
        return sum.isMultiple(of: 10)
    }

    /// A typed or scanned string reduced to the thirteen digits, or nil.
    ///
    /// Hyphens and spaces go (`978-0-316-47185-5` is how a book prints it);
    /// anything that is not then thirteen digits beginning `978` or `979`
    /// with a valid check digit is refused. **ISBN-10 is refused, not
    /// converted**: the shelf's rows carry ISBN-13 only (`EditionVolume.
    /// isbn13`), no source in the app emits an ISBN-10, and a barcode is
    /// never one — the conversion would be code for an input that cannot
    /// arrive through the camera. Recorded here so it is a decision and not
    /// an omission.
    nonisolated static func normalise(_ raw: String) -> String? {
        let digits = raw.filter { $0 != "-" && $0 != " " }
        guard digits.hasPrefix("978") || digits.hasPrefix("979"), isValidISBN13(digits) else {
            return nil
        }
        return digits
    }

    /// The row on this series' shelf with this ISBN, if any.
    ///
    /// Compared after `OpenLibraryEditions.normalise` on the row's side, the
    /// same fold `OwnedVolumeKey` applies, so a row whose source hyphenated
    /// its ISBN still matches. Nil is "not on this series' shelf" — the sheet
    /// says exactly that and looks nothing up, because a network lookup
    /// would need a source the reader has not been told about.
    nonisolated static func match(_ isbn: String, in shelves: [EditionShelf]) -> EditionVolume? {
        for shelf in shelves {
            for volume in shelf.volumes {
                guard let candidate = volume.isbn13 else { continue }
                if OpenLibraryEditions.normalise(candidate) == isbn { return volume }
            }
        }
        return nil
    }
}

/// VisionKit's live scanner, restricted to EAN-13 — the symbology every ISBN
/// barcode uses, and the one restriction that stops a QR code on the back
/// cover or a retailer's own sticker being read as a book.
///
/// Presented only after `ISBNScanSheet` has confirmed the device supports it
/// and the camera is authorised; this view assumes both. Neither check lives
/// here because both need a message and a way out, and a
/// `UIViewControllerRepresentable` has nowhere to draw one.
struct ISBNScannerView: UIViewControllerRepresentable {
    /// Every barcode payload the scanner reads, raw. Validation is the
    /// sheet's job, so the same payload string is what a test would hand it.
    let onRead: (String) -> Void
    /// `startScanning()` refused — the camera is in use by another app, or
    /// went away between the sheet's check and this view appearing.
    let onCouldNotStart: (any Error) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        do {
            try scanner.startScanning()
        } catch let error {
            onCouldNotStart(error)
        }
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onRead: onRead)
    }

    /// `@MainActor` because `DataScannerViewControllerDelegate` is, and the
    /// closure it holds is the sheet's, which mutates `@State`.
    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onRead: (String) -> Void

        init(onRead: @escaping (String) -> Void) {
            self.onRead = onRead
        }

        /// `didAdd`, not `didTapOn`: the reader is holding a book up to the
        /// camera, and asking them to then tap the highlight is a second
        /// step the barcode already answered.
        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                guard case let .barcode(barcode) = item, let payload = barcode.payloadStringValue else {
                    continue
                }
                onRead(payload)
            }
        }
    }
}

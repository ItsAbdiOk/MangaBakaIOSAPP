import Foundation
import Testing
@testable import MangaBaka

/// Tests for the review's F3 fix (persistence review, 2026-09-14): the output
/// buffer used to be sized straight from the trailer's `ISIZE` field with no
/// validation, so a truncated file could ask for up to 4 GB and get the
/// process killed before `Gunzip.Failure.decodeFailed` ever had a chance to
/// throw; a same-length corruption decoded to wrong bytes with no error at
/// all. Kept in a separate file from `GunzipTests` (this lane owns
/// `Gunzip.swift` but not `GunzipTests.swift`) rather than folding these in.
@Suite("Gunzip size cap and CRC32")
struct GunzipSizeCapTests {
    /// Same fixture `GunzipTests.plain` uses: gzip of "hello gzip world"
    /// (Python's `gzip` module, `mtime=0`, no filename) — 16 bytes
    /// uncompressed, 34 bytes total, no optional header sections.
    private static let plain: [UInt8] = [
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57,
        0x48, 0xaf, 0xca, 0x2c, 0x50, 0x28, 0xcf, 0x2f, 0xca, 0x49, 0x01, 0x00, 0x6b, 0x7d, 0xe8, 0xb7,
        0x10, 0x00, 0x00, 0x00
    ]

    // MARK: - Control: CRC32 itself

    /// The standard's own known-answer test (used by every CRC32
    /// implementation's test suite, e.g. zlib's): CRC32 of the ASCII bytes
    /// "123456789" is 0xCBF43926. If this fails, the table or the
    /// reflect/init/final-XOR logic is wrong, independent of anything gzip
    /// does — the control every measurement in this file depends on.
    @Test("CRC32 of the standard check string \"123456789\" is 0xCBF43926")
    func crc32KnownAnswer() {
        let bytes = [UInt8]("123456789".utf8)
        #expect(Gunzip.crc32(bytes) == 0xCBF4_3926)
    }

    @Test("CRC32 of an empty input is 0")
    func crc32OfEmptyIsZero() {
        #expect(Gunzip.crc32([]) == 0)
    }

    // MARK: - Control: both existing fixtures still decode

    /// Control for the tests below: fixing F3 must not break the two shapes
    /// `GunzipTests` already covers. If this fails, the size cap or the new
    /// CRC check is wrong, not just stricter.
    @Test("The plain fixture still decodes after the size cap and CRC check were added")
    func plainFixtureStillDecodes() throws {
        let decoded = try Gunzip.decompress(Data(Self.plain))
        #expect(String(data: decoded, encoding: .utf8) == "hello gzip world")
    }

    // MARK: - F3: implausible ISIZE

    /// Before the fix: the last four bytes of `plain` become the trailer's
    /// `ISIZE` field. Overwriting them with `0xFF` each makes the claimed
    /// uncompressed size 4,294,967,295 — a ~126,000,000:1 ratio against the
    /// 34-byte file, far past DEFLATE's 1032:1 ceiling. Before the fix this
    /// allocated a 4 GB array; the test's own success criterion (completing
    /// in under a second, enforced by xcodebuild's default per-test timeout
    /// combined with `#expect(throws:)` never reaching an allocation that
    /// size) is what proves the cap fired instead of the old unconditional
    /// allocation. Expected to fail on the current (pre-fix) code: it either
    /// hangs/crashes attempting the 4 GB allocation, or — if it survives —
    /// throws `.decodeFailed` from the length mismatch rather than being
    /// rejected up front; either way `Gunzip.Failure.decodeFailed` thrown
    /// promptly, as asserted here, was not the old behaviour.
    @Test("A file with a lying (implausibly large) ISIZE throws instead of allocating gigabytes")
    func implausibleISIZEThrowsWithoutHugeAllocation() {
        var corrupted = Self.plain
        for index in (corrupted.count - 8)..<corrupted.count {
            corrupted[index] = 0xFF
        }
        #expect(throws: Gunzip.Failure.decodeFailed) {
            try Gunzip.decompress(Data(corrupted))
        }
    }

    // MARK: - F3: truncated file

    /// This test used to assert `.truncatedHeader`, on the belief that
    /// `bytes.count - offset >= 8` "fires for a *missing* trailer". It does
    /// not, and cannot: nothing in a gzip stream marks where the payload
    /// ends, so a file with its last 10 bytes gone is 26 bytes that look
    /// exactly like a 16-byte payload followed by an 8-byte trailer. The
    /// guard only catches a file with fewer than 8 bytes left after the
    /// header.
    ///
    /// What actually happens, and what is asserted here: the last four bytes
    /// (DEFLATE payload, read as `ISIZE`) claim 1,238,646,735 bytes from an
    /// 8-byte payload, which `validatedDestinationSize` rejects as
    /// implausible — `.decodeFailed`, whose own doc comment already covers
    /// "a corrupt or truncated stream either way". That is the same
    /// protection the implausible-ISIZE test above pins, reached by a
    /// genuinely truncated file rather than a hand-edited trailer, which is
    /// what makes it worth keeping.
    @Test("A file with its trailer truncated away is rejected as an implausible size")
    func missingTrailerThrowsDecodeFailed() {
        let truncated = Self.plain.dropLast(10)
        #expect(throws: Gunzip.Failure.decodeFailed) {
            try Gunzip.decompress(Data(truncated))
        }
    }

    /// A file just below the 19-byte minimum (10-byte fixed header + 8-byte
    /// trailer + at least one payload byte is not actually required by the
    /// guard, which only checks `bytes.count > 18`) throws `truncatedHeader`,
    /// not `notGzip` — the relabelling F3 also asked for. Expected to fail on
    /// the current (pre-fix) code: the old combined guard threw `.notGzip`
    /// for this input because it checked length and magic bytes together.
    @Test("A file too short to hold a header and trailer throws truncatedHeader, not notGzip")
    func tooShortThrowsTruncatedHeaderNotNotGzip() {
        let short = Array(Self.plain.prefix(18))
        #expect(throws: Gunzip.Failure.truncatedHeader) {
            try Gunzip.decompress(Data(short))
        }
    }

    // MARK: - F3: CRC32 mismatch on same-length corruption

    /// Flips one bit of the last payload byte, which decodes to the same
    /// *length* (`compression_decode_buffer`'s only prior check) but
    /// different bytes. Before CRC verification this decoded silently with
    /// no error, which is exactly the "same-length corruption decodes to
    /// wrong bytes silently" half of F3. Expected to fail on the current
    /// (pre-fix) code: `Gunzip.decompress` returns successfully instead of
    /// throwing, so `#expect(throws:)` fails because no error was thrown at
    /// all.
    @Test("A single flipped payload byte fails CRC32 verification rather than decoding silently")
    func flippedPayloadByteFailsCRC() {
        var corrupted = Self.plain
        // Index 24 is inside the DEFLATE payload (offset 10..<26 for this
        // fixture's headerless stream, trailer starts at 26) — flipping it
        // changes a bit without changing the compressed length, so
        // `compression_decode_buffer` still produces 16 bytes; only CRC32
        // over those (now-wrong) bytes can catch it.
        corrupted[24] ^= 0x01
        #expect(throws: Gunzip.Failure.crcMismatch) {
            try Gunzip.decompress(Data(corrupted))
        }
    }
}

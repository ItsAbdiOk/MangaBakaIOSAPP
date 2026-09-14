import Compression
import Foundation

/// Decompresses a `.gz` file (RFC 1952) using Apple's `Compression` framework.
///
/// Foundation has no built-in gzip reader. `Compression`'s `.zlib` algorithm
/// decodes raw DEFLATE (RFC 1951) — the payload every zlib and gzip stream
/// wraps — but it does not understand either container's own header or
/// trailer. A gzip file adds a 10-byte-minimum header (with optional name,
/// comment, extra-field and CRC16 sections a real encoder may or may not
/// include) and an 8-byte trailer (CRC32 then the uncompressed size, both
/// little-endian). This walks past the header, hands the framework exactly the
/// DEFLATE bytes in between, and uses the trailer's own stated size to size the
/// output buffer, bounded against the compressed size (see
/// `validatedDestinationSize`) — exact for anything under that bound, which
/// covers every use this app has for it, and rejected rather than trusted
/// blindly above it. The trailer's CRC32 is also verified over the decoded
/// output, so a same-length corruption fails loudly instead of decoding to
/// wrong bytes silently.
enum Gunzip {
    enum Failure: Error, Equatable {
        /// The header did not carry gzip's magic bytes (0x1f 0x8b) and
        /// DEFLATE's method byte (8).
        case notGzip
        /// Too short to be a complete gzip stream — either the fixed header,
        /// an optional header section, or the 8-byte trailer ran past the
        /// end of the data.
        case truncatedHeader
        /// Either `compression_decode_buffer` did not produce exactly as
        /// many bytes as the trailer promised, or the trailer's own claimed
        /// size (`ISIZE`) was rejected outright as implausible before
        /// decoding was attempted — see the size-cap comment at the call
        /// site. A corrupt or truncated stream either way.
        case decodeFailed
        /// The decoded output's CRC32 did not match the trailer's — same
        /// length as expected, wrong bytes. `compression_decode_buffer`
        /// alone cannot catch this: a same-length corruption still produces
        /// exactly `destinationSize` bytes.
        case crcMismatch
    }

    /// Bit flags in a gzip header's FLG byte (RFC 1952 §2.3.1).
    private static let flagExtra: UInt8 = 0x04
    private static let flagName: UInt8 = 0x08
    private static let flagComment: UInt8 = 0x10
    private static let flagHeaderCRC: UInt8 = 0x02

    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        // A 12-byte file cannot hold the 10-byte fixed header plus an
        // 8-byte trailer — that is a truncation, not "this isn't gzip".
        // Checked separately from the magic bytes below so the two failures
        // are distinguishable (found while fixing the size-cap bug: a
        // truncated-file test needs `.truncatedHeader`, not `.notGzip`).
        guard bytes.count > 18 else { throw Failure.truncatedHeader }
        guard bytes[0] == 0x1f, bytes[1] == 0x8b,
              bytes[2] == 8 // CM: only DEFLATE is defined
        else { throw Failure.notGzip }

        let flags = bytes[3]
        var offset = 10 // fixed header: magic(2) + CM(1) + FLG(1) + MTIME(4) + XFL(1) + OS(1)

        if flags & flagExtra != 0 {
            guard offset + 2 <= bytes.count else { throw Failure.truncatedHeader }
            let extraLength = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + extraLength
        }
        if flags & flagName != 0 {
            offset = try skipNullTerminated(bytes, from: offset)
        }
        if flags & flagComment != 0 {
            offset = try skipNullTerminated(bytes, from: offset)
        }
        if flags & flagHeaderCRC != 0 {
            offset += 2
        }
        // 8-byte trailer: CRC32 then ISIZE, each little-endian.
        guard offset < bytes.count, bytes.count - offset >= 8 else { throw Failure.truncatedHeader }

        let trailerStart = bytes.count - 8
        let sizeBytes = bytes[(trailerStart + 4)...]
        let uncompressedSize = sizeBytes.enumerated().reduce(UInt32(0)) { partial, entry in
            partial | (UInt32(entry.element) << (8 * entry.offset))
        }

        let payload = Array(bytes[offset..<trailerStart])
        let destinationSize = try validatedDestinationSize(
            uncompressedSize: uncompressedSize, payload: payload
        )
        var destination = [UInt8](repeating: 0, count: destinationSize)

        let decodedCount = payload.withUnsafeBufferPointer { source -> Int in
            destination.withUnsafeMutableBufferPointer { dest -> Int in
                guard let sourceBase = source.baseAddress, let destBase = dest.baseAddress else { return 0 }
                return compression_decode_buffer(
                    destBase, destinationSize,
                    sourceBase, source.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard decodedCount == destinationSize else { throw Failure.decodeFailed }
        try verifyCRC(of: destination, against: bytes, trailerStart: trailerStart)
        return Data(destination)
    }

    /// A truncated file's last four bytes are DEFLATE payload, not a real
    /// ISIZE — read as a size, they are effectively random over 0...4 GB, and
    /// `[UInt8](repeating: 0, count: destinationSize)` at that size is
    /// attempted before `compression_decode_buffer` gets a chance to fail,
    /// which iOS answers by killing the process (review finding F3,
    /// 2026-09-14 — a truncated `OfflineIndex.json.gz` is a build-time
    /// hazard this general-purpose utility should not carry). Bound the
    /// allocation instead of trusting the trailer: DEFLATE's stored-block
    /// mode caps expansion at 1032:1 (RFC 1951 — a stored block adds a
    /// 5-byte header per up-to-65,535-byte block, so the smallest possible
    /// compressed encoding of N output bytes is bounded near N/1032), so any
    /// ISIZE claiming a bigger ratio than that (plus 64 bytes of slack for
    /// tiny inputs) is provably a lie regardless of what the trailer says.
    /// The absolute 64 MB ceiling on top is a guess, not derived — this
    /// app's real payload is 4.75 MB (`OfflineIndex.json.gz`, measured
    /// 2026-09-14), so 64 MB is more than 13x headroom for any file this app
    /// actually ships.
    private static func validatedDestinationSize(uncompressedSize: UInt32, payload: [UInt8]) throws -> Int {
        let maximumPlausibleSize = min(payload.count * 1032 + 64, 64 * 1024 * 1024)
        guard Int(uncompressedSize) <= maximumPlausibleSize else { throw Failure.decodeFailed }
        return max(Int(uncompressedSize), 1)
    }

    /// The trailer's CRC32, little-endian, immediately before ISIZE.
    /// `compression_decode_buffer` only proves the decoded *length* matched
    /// — a same-length corruption (one flipped payload byte) decodes to the
    /// right number of wrong bytes with no error from the framework at all
    /// (review finding F3). This is the check that catches that.
    private static func verifyCRC(of destination: [UInt8], against bytes: [UInt8], trailerStart: Int) throws {
        let crcBytes = bytes[trailerStart..<(trailerStart + 4)]
        let expectedCRC = crcBytes.enumerated().reduce(UInt32(0)) { partial, entry in
            partial | (UInt32(entry.element) << (8 * entry.offset))
        }
        guard Self.crc32(destination) == expectedCRC else { throw Failure.crcMismatch }
    }

    /// Table-driven CRC32 (zlib/gzip's polynomial, reflected: 0xEDB88320),
    /// checked against the standard's own known-answer test in
    /// `GunzipTests` (CRC32 of "123456789" == 0xCBF43926) — the control that
    /// proves this implementation, not just gzip's, computes the right
    /// value. `nonisolated` so tests can call it without an actor hop (this
    /// enum carries no isolation itself, but the annotation documents that
    /// deliberately for the tests that reach it directly).
    nonisolated static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            let tableIndex = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ Self.crc32Table[tableIndex]
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// Precomputed once: for each possible byte value, the effect of eight
    /// rounds of the polynomial division that `crc32(_:)` otherwise repeats
    /// per bit. Standard technique for this algorithm; not specific to this
    /// file's data.
    private static let crc32Table: [UInt32] = (0...255).map { byte -> UInt32 in
        var value = UInt32(byte)
        for _ in 0..<8 {
            value = (value & 1 != 0) ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    private static func skipNullTerminated(_ bytes: [UInt8], from start: Int) throws -> Int {
        var index = start
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        guard index < bytes.count else { throw Failure.truncatedHeader }
        return index + 1
    }
}

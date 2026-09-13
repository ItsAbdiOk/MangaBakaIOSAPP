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
/// output buffer — which is exact for anything under 4 GB uncompressed, which
/// covers every use this app has for it.
enum Gunzip {
    enum Failure: Error, Equatable {
        /// Too short to be a gzip stream, or the header did not carry gzip's
        /// magic bytes (0x1f 0x8b) and DEFLATE's method byte (8).
        case notGzip
        /// The header's optional sections ran past the end of the data.
        case truncatedHeader
        /// `compression_decode_buffer` did not produce exactly as many bytes
        /// as the trailer promised — a corrupt or truncated stream.
        case decodeFailed
    }

    /// Bit flags in a gzip header's FLG byte (RFC 1952 §2.3.1).
    private static let flagExtra: UInt8 = 0x04
    private static let flagName: UInt8 = 0x08
    private static let flagComment: UInt8 = 0x10
    private static let flagHeaderCRC: UInt8 = 0x02

    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18,
              bytes[0] == 0x1f, bytes[1] == 0x8b,
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
        let destinationSize = max(Int(uncompressedSize), 1)
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
        return Data(destination)
    }

    private static func skipNullTerminated(_ bytes: [UInt8], from start: Int) throws -> Int {
        var index = start
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        guard index < bytes.count else { throw Failure.truncatedHeader }
        return index + 1
    }
}

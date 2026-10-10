//
//  ByteUtilities.swift
//  Metadata Wash
//

import Compression
import Foundation

extension Data {
    nonisolated func uint16BE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let i = startIndex + offset
        return UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }

    nonisolated func uint32BE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }

    nonisolated func uint32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let i = startIndex + offset
        return UInt32(self[i + 3]) << 24 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 1]) << 8 | UInt32(self[i])
    }

    nonisolated func uint64BE(at offset: Int) -> UInt64? {
        guard let high = uint32BE(at: offset), let low = uint32BE(at: offset + 4) else { return nil }
        return UInt64(high) << 32 | UInt64(low)
    }

    nonisolated func fourCC(at offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return String(decoding: self[(startIndex + offset)..<(startIndex + offset + 4)], as: UTF8.self)
    }

    /// Zero-based sub-range copy (Data slices keep their parent's indices).
    nonisolated func bytes(_ range: Range<Int>) -> Data {
        let lower = Swift.max(0, Swift.min(range.lowerBound, count))
        let upper = Swift.max(lower, Swift.min(range.upperBound, count))
        return Data(self[(startIndex + lower)..<(startIndex + upper)])
    }

    nonisolated static func uint32BE(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    nonisolated static func uint32LE(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)])
    }

    /// Latin-1 / UTF-8 tolerant text for scanning.
    nonisolated var looseText: String {
        String(data: self, encoding: .utf8) ?? String(data: self, encoding: .isoLatin1) ?? ""
    }
}

/// Bounded zlib inflate, so a malicious "zip bomb" text chunk cannot exhaust memory.
nonisolated enum Inflate {
    static func zlib(_ data: Data, limit: Int = 4 << 20) -> Data? {
        // Skip the 2-byte zlib header; the Compression framework expects raw DEFLATE.
        guard data.count > 2 else { return nil }
        let raw = data.bytes(2..<data.count)
        var output = Data()
        let bufferSize = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }
        var stream = compression_stream(dst_ptr: destination, dst_size: 0, src_ptr: destination, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(&stream) }
        return raw.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Data? in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.src_ptr = base
            stream.src_size = source.count
            while true {
                stream.dst_ptr = destination
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(destination, count: bufferSize - stream.dst_size)
                if output.count > limit { return output.prefix(limit) }
                switch status {
                case COMPRESSION_STATUS_OK: continue
                case COMPRESSION_STATUS_END: return output
                default: return output.isEmpty ? nil : output
                }
            }
        }
    }
}

/// Builds the smallest valid EXIF block that only carries an orientation value.
nonisolated enum MinimalExif {
    /// TIFF structure (big-endian) with a single IFD0 entry: Orientation (0x0112).
    static func orientationTIFF(_ orientation: Int) -> Data {
        var d = Data("MM".utf8)
        d.append(contentsOf: [0x00, 0x2A])                 // TIFF magic
        d.append(Data.uint32BE(8))                          // IFD0 offset
        d.append(contentsOf: [0x00, 0x01])                 // 1 entry
        d.append(contentsOf: [0x01, 0x12, 0x00, 0x03])     // tag 0x0112, type SHORT
        d.append(Data.uint32BE(1))                          // count
        d.append(contentsOf: [UInt8(orientation >> 8 & 0xFF), UInt8(orientation & 0xFF), 0x00, 0x00])
        d.append(Data.uint32BE(0))                          // no next IFD
        return d
    }

    /// JPEG APP1 segment ("Exif\0\0" + TIFF), including marker and length.
    static func jpegAPP1(orientation: Int) -> Data {
        let payload = Data("Exif".utf8) + Data([0, 0]) + orientationTIFF(orientation)
        let length = payload.count + 2
        return Data([0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)]) + payload
    }

    /// Reads the orientation value from a TIFF-structured EXIF block, if present.
    static func orientation(inTIFF tiff: Data) -> Int? {
        guard tiff.count >= 8 else { return nil }
        let littleEndian = tiff.bytes(0..<2) == Data("II".utf8)
        func u16(_ o: Int) -> Int? {
            guard o + 2 <= tiff.count else { return nil }
            let a = Int(tiff[tiff.startIndex + o]), b = Int(tiff[tiff.startIndex + o + 1])
            return littleEndian ? b << 8 | a : a << 8 | b
        }
        func u32(_ o: Int) -> Int? {
            guard let hi = u16(littleEndian ? o + 2 : o), let lo = u16(littleEndian ? o : o + 2) else { return nil }
            return hi << 16 | lo
        }
        guard let ifd = u32(4), let entries = u16(ifd) else { return nil }
        for index in 0..<min(entries, 512) {
            let entry = ifd + 2 + index * 12
            if u16(entry) == 0x0112 { return u16(entry + 8) }
        }
        return nil
    }
}

//
//  BMFFContainer.swift
//  Metadata Wash
//

import Foundation

/// ISO base media file format (MP4, MOV, M4V, HEIC, AVIF) box walker.
///
/// Works on file handles so multi-gigabyte videos are never loaded into memory.
/// Removal is done *in place*: a metadata box keeps its size but becomes a `free`
/// box with zeroed payload. Because no byte moves, every absolute offset (`stco`,
/// `co64`, `iloc`) stays valid and the media data is untouched. This is the same
/// technique watermarks-remover uses for C2PA `uuid` boxes.
nonisolated enum BMFFContainer {
    struct Box {
        var type: String
        var offset: UInt64
        var headerSize: UInt64
        var size: UInt64
        var payloadOffset: UInt64 { offset + headerSize }
        var payloadSize: UInt64 { size - headerSize }
        var end: UInt64 { offset + size }
    }

    /// Reads the boxes in `range` (non-recursive).
    static func boxes(in handle: FileHandle, from start: UInt64, to end: UInt64) throws -> [Box] {
        var result: [Box] = []
        var offset = start
        while offset + 8 <= end {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 16), header.count >= 8,
                  let size32 = header.uint32BE(at: 0), let type = header.fourCC(at: 4) else { break }
            var size = UInt64(size32)
            var headerSize: UInt64 = 8
            if size32 == 1 {
                guard let size64 = header.uint64BE(at: 8) else { break }
                size = size64
                headerSize = 16
            } else if size32 == 0 {
                size = end - offset
            }
            guard size >= headerSize, offset + size <= end else { break }
            result.append(Box(type: type, offset: offset, headerSize: headerSize, size: size))
            offset += size
        }
        return result
    }

    static func fileSize(_ handle: FileHandle) throws -> UInt64 { try handle.seekToEnd() }

    static func payload(of box: Box, in handle: FileHandle, limit: Int) throws -> Data {
        try handle.seek(toOffset: box.payloadOffset)
        return try handle.read(upToCount: Int(min(box.payloadSize, UInt64(limit)))) ?? Data()
    }

    static func isC2PAUUID(_ payload: Data) -> Bool {
        payload.prefix(16) == Data(AISignatures.c2paBMFFUUID) || payload.bytes(4..<20) == Data(AISignatures.c2paBMFFUUID)
    }

    // MARK: Inspection

    static func scan(_ url: URL, format: MediaFormat) -> [MetadataItem] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? fileSize(handle), let top = try? boxes(in: handle, from: 0, to: size) else { return [] }
        var items: [MetadataItem] = []
        for box in top {
            switch box.type {
            case "uuid":
                guard let head = try? payload(of: box, in: handle, limit: 20) else { continue }
                if isC2PAUUID(head) {
                    items.append(MetadataItem(category: .contentCredentials, group: "BMFF:uuid", name: "C2PA manifest store",
                                              value: ByteCountFormatter.string(fromByteCount: Int64(box.size), countStyle: .file),
                                              source: .structure, reason: "C2PA ContentProvenanceBox"))
                } else if head.prefix(16) != Data(AISignatures.xmpBMFFUUID) {
                    items.append(MetadataItem(category: .other, group: "BMFF:uuid", name: "Vendor UUID box",
                                              value: head.prefix(16).map { String(format: "%02x", $0) }.joined(),
                                              source: .structure))
                }
            case "jumb", "c2pa":
                items.append(MetadataItem(category: .contentCredentials, group: "BMFF:\(box.type)", name: "JUMBF box",
                                          value: "\(box.size) bytes", source: .structure, reason: "C2PA JUMBF box"))
            case "mdat" where format.kind == .video:
                if let encoder = bitstreamEncoderSignature(in: handle, mdat: box) {
                    items.append(MetadataItem(category: .software, group: "Video bitstream", name: "Encoder settings (SEI)",
                                              value: encoder, source: .structure, removability: .requiresReencoding,
                                              reason: "Stored inside the compressed video frames"))
                }
            default:
                break
            }
        }
        return items
    }

    /// Encoders such as x264/x265 write their name and settings into an SEI message
    /// inside the first frames. Stream copying keeps it; only re-encoding removes it.
    static func bitstreamEncoderSignature(in handle: FileHandle, mdat: Box) -> String? {
        guard let head = try? payload(of: mdat, in: handle, limit: 2 << 20) else { return nil }
        for marker in ["x264 - core", "x265 (build", "HandBrake", "Lavc"] {
            guard let range = head.range(of: Data(marker.utf8)) else { continue }
            let snippet = head[range.lowerBound..<min(range.lowerBound + 60, head.endIndex)]
            let text = String(decoding: snippet.prefix { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
            return text.isEmpty ? marker : text
        }
        return nil
    }

    // MARK: In-place removal

    /// Neutralizes C2PA and XMP `uuid` boxes and top-level JUMBF boxes. Safe for HEIF/AVIF and video.
    static func neutralizeProvenanceBoxes(at url: URL) throws -> [String] {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try fileSize(handle)
        var steps: [String] = []
        for box in try boxes(in: handle, from: 0, to: size) {
            switch box.type {
            case "uuid":
                let head = try payload(of: box, in: handle, limit: 20)
                if isC2PAUUID(head) {
                    try freeBox(box, in: handle)
                    steps.append("Removed C2PA manifest box (\(box.size) bytes)")
                } else if head.prefix(16) == Data(AISignatures.xmpBMFFUUID) {
                    try freeBox(box, in: handle)
                    steps.append("Removed XMP box")
                }
            case "jumb", "c2pa":
                try freeBox(box, in: handle)
                steps.append("Removed JUMBF box")
            default:
                break
            }
        }
        return steps
    }

    /// Fallback movie cleaner used when FFmpeg is unavailable or fails: removes user
    /// data and iTunes-style metadata, zeroes creation/modification times and clears
    /// handler names — all without moving a single byte of media data.
    static func neutralizeMovieMetadata(at url: URL) throws -> [String] {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try fileSize(handle)
        var counts: [String: Int] = [:]

        func visit(_ boxes: [Box], path: String) throws {
            for box in boxes {
                let here = path.isEmpty ? box.type : "\(path)/\(box.type)"
                switch box.type {
                case "udta", "meta" where path.hasPrefix("moov"):
                    try freeBox(box, in: handle)
                    counts["\(here) metadata", default: 0] += 1
                case "moov", "trak", "mdia", "minf":
                    try visit(try self.boxes(in: handle, from: box.payloadOffset, to: box.end), path: here)
                case "mvhd", "tkhd", "mdhd":
                    try zeroTimes(in: box, handle: handle)
                    counts["\(box.type) timestamps", default: 0] += 1
                case "hdlr":
                    // version/flags(4) + pre_defined(4) + handler_type(4) + reserved(12) precede the name.
                    let nameOffset: UInt64 = 24
                    if box.payloadSize > nameOffset {
                        try zero(from: box.payloadOffset + nameOffset, count: box.payloadSize - nameOffset, in: handle)
                        counts["handler names", default: 0] += 1
                    }
                default:
                    break
                }
            }
        }
        try visit(try boxes(in: handle, from: 0, to: size), path: "")
        return counts.isEmpty ? [] : ["Neutralized in place: " + counts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")]
    }

    private static func zeroTimes(in box: Box, handle: FileHandle) throws {
        try handle.seek(toOffset: box.payloadOffset)
        guard let version = try handle.read(upToCount: 1)?.first else { return }
        let width: UInt64 = version == 1 ? 8 : 4
        guard box.payloadSize >= 4 + width * 2 else { return }
        try zero(from: box.payloadOffset + 4, count: width * 2, in: handle)
    }

    private static func freeBox(_ box: Box, in handle: FileHandle) throws {
        try handle.seek(toOffset: box.offset + 4)
        try handle.write(contentsOf: Data("free".utf8))
        try zero(from: box.payloadOffset, count: box.payloadSize, in: handle)
    }

    private static func zero(from offset: UInt64, count: UInt64, in handle: FileHandle) throws {
        try handle.seek(toOffset: offset)
        var remaining = count
        let block = Data(count: 1 << 20)
        while remaining > 0 {
            let n = Int(min(remaining, UInt64(block.count)))
            try handle.write(contentsOf: block.prefix(n))
            remaining -= UInt64(n)
        }
    }
}

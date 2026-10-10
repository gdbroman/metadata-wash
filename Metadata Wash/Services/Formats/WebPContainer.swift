//
//  WebPContainer.swift
//  Metadata Wash
//

import Foundation

/// Native WebP (RIFF) scanner and lossless metadata stripper.
///
/// Keeps bitstream, alpha, animation and ICC chunks; drops EXIF, XMP, C2PA and
/// unknown chunks, and clears the matching VP8X feature flags. A non-default EXIF
/// orientation is written back as a minimal EXIF chunk.
nonisolated enum WebPContainer {
    static let preservedChunks: Set<String> = ["VP8 ", "VP8L", "VP8X", "ALPH", "ANIM", "ANMF", "ICCP"]

    struct Chunk {
        var fourCC: String
        var offset: Int
        var length: Int
        var payloadRange: Range<Int> { (offset + 8)..<(offset + 8 + length) }
        var paddedEnd: Int { offset + 8 + length + (length & 1) }
    }

    static func chunks(in data: Data) throws -> [Chunk] {
        guard data.count >= 12, data.fourCC(at: 0) == "RIFF", data.fourCC(at: 8) == "WEBP" else {
            throw CleaningError.malformedFile("missing RIFF/WEBP header")
        }
        var result: [Chunk] = []
        var offset = 12
        while offset + 8 <= data.count {
            guard let fourCC = data.fourCC(at: offset), let length = data.uint32LE(at: offset + 4) else { break }
            let chunk = Chunk(fourCC: fourCC, offset: offset, length: Int(length))
            guard chunk.payloadRange.upperBound <= data.count else {
                throw CleaningError.malformedFile("WebP chunk \(fourCC) is truncated")
            }
            result.append(chunk)
            offset = min(chunk.paddedEnd, data.count)
        }
        guard result.contains(where: { ["VP8 ", "VP8L", "ANMF"].contains($0.fourCC) }) else {
            throw CleaningError.malformedFile("WebP has no image data")
        }
        return result
    }

    static func orientation(in data: Data, chunks: [Chunk]) -> Int? {
        guard let exif = chunks.first(where: { $0.fourCC == "EXIF" }) else { return nil }
        var payload = data.bytes(exif.payloadRange)
        if payload.starts(with: Data("Exif\0\0".utf8)) { payload = payload.bytes(6..<payload.count) }
        return MinimalExif.orientation(inTIFF: payload)
    }

    static func strip(_ data: Data) throws -> (Data, [String]) {
        let all = try chunks(in: data)
        let orientation = orientation(in: data, chunks: all).flatMap { (2...8).contains($0) ? $0 : nil }
        var body = Data("WEBP".utf8)
        var dropped: [String] = []
        let canCarryExif = all.contains { $0.fourCC == "VP8X" }

        for chunk in all {
            guard preservedChunks.contains(chunk.fourCC) else {
                dropped.append(chunk.fourCC.trimmingCharacters(in: .whitespaces))
                continue
            }
            var payload = data.bytes(chunk.payloadRange)
            if chunk.fourCC == "VP8X", !payload.isEmpty {
                // Bit 3 = EXIF, bit 2 = XMP. Keep EXIF only when orientation is re-added.
                var flags = payload[payload.startIndex] & ~0x04
                if orientation == nil { flags &= ~0x08 } else { flags |= 0x08 }
                payload[payload.startIndex] = flags
            }
            body.append(Data(chunk.fourCC.utf8))
            body.append(Data.uint32LE(UInt32(payload.count)))
            body.append(payload)
            if payload.count & 1 == 1 { body.append(0) }
        }
        var steps: [String] = []
        if let orientation, canCarryExif {
            // EXIF chunks belong after the image data.
            let exif = MinimalExif.orientationTIFF(orientation)
            body.append(Data("EXIF".utf8))
            body.append(Data.uint32LE(UInt32(exif.count)))
            body.append(exif)
            if exif.count & 1 == 1 { body.append(0) }
            steps.append("Kept orientation (\(orientation)) in a minimal EXIF chunk")
        }
        if !dropped.isEmpty { steps.insert("Removed WebP chunks: " + dropped.joined(separator: ", "), at: 0) }
        return (Data("RIFF".utf8) + Data.uint32LE(UInt32(body.count)) + body, steps)
    }

    static func scan(_ data: Data) -> [MetadataItem] {
        guard let chunks = try? chunks(in: data) else { return [] }
        var items: [MetadataItem] = []
        for chunk in chunks where !preservedChunks.contains(chunk.fourCC) {
            let name = chunk.fourCC.trimmingCharacters(in: .whitespaces)
            switch name {
            case "EXIF", "XMP":
                continue // Reported in detail by ExifTool.
            case "C2PA":
                items.append(MetadataItem(category: .contentCredentials, group: "WebP:C2PA", name: "C2PA manifest store",
                                          value: "\(chunk.length) bytes", source: .structure, reason: "C2PA RIFF chunk"))
            default:
                var item = MetadataItem(category: .other, group: "WebP:\(name)", name: "Unknown chunk",
                                        value: "\(chunk.length) bytes", source: .structure)
                if let marker = data.bytes(chunk.payloadRange).firstMarker(of: AISignatures.c2paByteMarkers) {
                    item.category = .contentCredentials
                    item.reason = "Contains C2PA marker “\(marker)”"
                }
                items.append(item)
            }
        }
        return items
    }
}

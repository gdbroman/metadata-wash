//
//  PNGContainer.swift
//  Metadata Wash
//

import Foundation

/// Native PNG chunk scanner and lossless metadata stripper.
///
/// Cleaning keeps an explicit allow-list of chunks needed to decode and render the
/// image (including color management, HDR and APNG animation chunks) and copies
/// them byte-for-byte. Image data (IDAT/fdAT) is never decoded or recompressed.
/// Every other chunk — tEXt/zTXt/iTXt text (where Stable Diffusion, ComfyUI and
/// NovelAI store prompts and workflows), eXIf, tIME, C2PA `caBX` and unknown
/// private chunks — is dropped.
nonisolated enum PNGContainer {
    static let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// Chunks required to decode or correctly render the image.
    static let preservedChunks: Set<String> = [
        "IHDR", "PLTE", "IDAT", "IEND", "tRNS",
        "gAMA", "cHRM", "sRGB", "iCCP", "sBIT", "cICP", "mDCV", "mDCv", "cLLI", "cLLi", "bKGD", "pHYs",
        "acTL", "fcTL", "fdAT",
    ]

    struct Chunk {
        var type: String
        var offset: Int        // start of the length field
        var length: Int
        var payloadRange: Range<Int> { (offset + 8)..<(offset + 8 + length) }
        var totalRange: Range<Int> { offset..<(offset + 12 + length) }
    }

    static func chunks(in data: Data) throws -> [Chunk] {
        guard data.prefix(8) == signature else { throw CleaningError.malformedFile("missing PNG signature") }
        var result: [Chunk] = []
        var offset = 8
        while offset + 12 <= data.count {
            guard let length = data.uint32BE(at: offset), let type = data.fourCC(at: offset + 4) else { break }
            let chunk = Chunk(type: type, offset: offset, length: Int(length))
            guard chunk.totalRange.upperBound <= data.count else {
                throw CleaningError.malformedFile("PNG chunk \(type) is truncated")
            }
            result.append(chunk)
            offset = chunk.totalRange.upperBound
            if type == "IEND" { break }
        }
        guard result.first?.type == "IHDR", result.contains(where: { $0.type == "IEND" }) else {
            throw CleaningError.malformedFile("PNG is missing IHDR or IEND")
        }
        return result
    }

    /// Structural findings: every non-image chunk, with decoded text where possible.
    static func scan(_ data: Data) -> [MetadataItem] {
        guard let chunks = try? chunks(in: data) else { return [] }
        var items: [MetadataItem] = []
        for chunk in chunks where !preservedChunks.contains(chunk.type) {
            let payload = data.bytes(chunk.payloadRange)
            switch chunk.type {
            case "tEXt", "zTXt", "iTXt":
                let (key, text) = decodeText(type: chunk.type, payload: payload)
                var item = MetadataItem(category: .comments, group: "PNG:\(chunk.type)", name: key, value: text, source: .structure)
                if let reason = AISignatures.aiReason(name: key, value: text) {
                    item.category = .aiGeneration
                    item.reason = reason
                } else if key.caseInsensitiveCompare("XML:com.adobe.xmp") == .orderedSame {
                    item.category = .descriptive
                } else if ["software", "source"].contains(key.lowercased()) {
                    item.category = .software
                } else if ["author", "copyright", "disclaimer"].contains(key.lowercased()) {
                    item.category = .people
                } else if key.lowercased().contains("time") || key.lowercased().contains("date") {
                    item.category = .timestamps
                }
                if text.range(of: "jumbf", options: .caseInsensitive) != nil, text.localizedCaseInsensitiveContains("provenance") {
                    item.category = .contentCredentials
                    item.reason = "XMP points to a C2PA manifest"
                }
                items.append(item)
            case "caBX":
                items.append(MetadataItem(category: .contentCredentials, group: "PNG:caBX", name: "C2PA manifest store",
                                          value: "\(chunk.length) bytes", source: .structure,
                                          reason: "C2PA JUMBF chunk"))
            case "eXIf":
                items.append(MetadataItem(category: .camera, group: "PNG:eXIf", name: "EXIF block",
                                          value: "\(chunk.length) bytes", source: .structure))
            case "tIME":
                items.append(MetadataItem(category: .timestamps, group: "PNG:tIME", name: "Last modification time",
                                          value: formatTime(payload), source: .structure))
            default:
                var item = MetadataItem(category: .other, group: "PNG:\(chunk.type)", name: "Ancillary chunk",
                                        value: "\(chunk.length) bytes", source: .structure)
                if let marker = payload.firstMarker(of: AISignatures.c2paByteMarkers) {
                    item.category = .contentCredentials
                    item.reason = "Contains C2PA marker “\(marker)”"
                }
                items.append(item)
            }
        }
        return items
    }

    /// Rebuilds the file from preserved chunks only.
    static func strip(_ data: Data) throws -> (Data, [String]) {
        let all = try chunks(in: data)
        var output = signature
        var dropped: [String: Int] = [:]
        for chunk in all {
            if preservedChunks.contains(chunk.type) {
                output.append(data.bytes(chunk.totalRange))
            } else {
                dropped[chunk.type, default: 0] += 1
            }
        }
        let summary = dropped.sorted { $0.key < $1.key }.map { "\($0.value)× \($0.key)" }
        return (output, summary.isEmpty ? [] : ["Removed PNG chunks: " + summary.joined(separator: ", ")])
    }

    static func decodeText(type: String, payload: Data) -> (key: String, text: String) {
        guard let nul = payload.firstIndex(of: 0) else { return ("(unnamed)", payload.looseText) }
        let key = String(decoding: payload[payload.startIndex..<nul], as: UTF8.self)
        let rest = payload[(nul + 1)...]
        switch type {
        case "tEXt":
            return (key, String(data: Data(rest), encoding: .isoLatin1) ?? "")
        case "zTXt":
            guard rest.count > 1 else { return (key, "") }
            let compressed = Data(rest.dropFirst())
            return (key, Inflate.zlib(compressed)?.looseText ?? "(compressed, \(compressed.count) bytes)")
        default: // iTXt: flag, method, language\0, translated keyword\0, text
            let bytes = Data(rest)
            guard bytes.count >= 2 else { return (key, "") }
            let compressed = bytes[bytes.startIndex] == 1
            var cursor = bytes.startIndex + 2
            for _ in 0..<2 {
                guard let end = bytes[cursor...].firstIndex(of: 0) else { return (key, "") }
                cursor = end + 1
            }
            let body = Data(bytes[cursor...])
            if compressed { return (key, Inflate.zlib(body)?.looseText ?? "(compressed, \(body.count) bytes)") }
            return (key, String(decoding: body, as: UTF8.self))
        }
    }

    private static func formatTime(_ payload: Data) -> String {
        guard payload.count >= 7, let year = payload.uint16BE(at: 0) else { return "\(payload.count) bytes" }
        let p = [UInt8](payload)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d UTC", year, p[2], p[3], p[4], p[5], p[6])
    }
}

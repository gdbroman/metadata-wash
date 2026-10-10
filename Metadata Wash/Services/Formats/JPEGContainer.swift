//
//  JPEGContainer.swift
//  Metadata Wash
//

import Foundation

/// Native JPEG segment scanner and lossless metadata stripper.
///
/// The entropy-coded scans are copied byte-for-byte, so pixels are never
/// recompressed. Kept: frame/table/scan segments, APP0 JFIF, APP2 ICC profile
/// chunks and APP14 Adobe (needed for correct color conversion). Dropped: EXIF
/// and XMP (APP1), MPF/FlashPix (APP2), IPTC/Photoshop (APP13), JUMBF/C2PA
/// (APP11), comments, all other APPn segments and any data after the end-of-image
/// marker. A non-default EXIF orientation is written back as a minimal EXIF block
/// so the image does not appear rotated.
nonisolated enum JPEGContainer {
    struct Segment {
        var marker: UInt8
        var range: Range<Int>          // marker through end of segment (and entropy data for SOS)
        var payloadRange: Range<Int>   // after the 2-byte length (empty for standalone markers)
    }

    struct Layout {
        var segments: [Segment]
        var endOfImage: Int            // offset just past FFD9
        var trailerRange: Range<Int>   // data after EOI (may be empty)
    }

    static func layout(of data: Data) throws -> Layout {
        let n = data.count
        guard n >= 4, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 else {
            throw CleaningError.malformedFile("missing JPEG start-of-image marker")
        }
        let bytes = [UInt8](data)
        var segments: [Segment] = []
        var i = 2
        while i < n {
            guard bytes[i] == 0xFF else { throw CleaningError.malformedFile("unexpected byte at offset \(i)") }
            var m = i + 1
            while m < n, bytes[m] == 0xFF { m += 1 }     // fill bytes
            guard m < n else { break }
            let marker = bytes[m]
            let start = m - 1
            if marker == 0xD9 {
                let end = m + 1
                return Layout(segments: segments, endOfImage: end, trailerRange: end..<n)
            }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) {
                segments.append(Segment(marker: marker, range: start..<(m + 1), payloadRange: (m + 1)..<(m + 1)))
                i = m + 1
                continue
            }
            guard m + 2 < n else { throw CleaningError.malformedFile("truncated segment header") }
            let length = Int(bytes[m + 1]) << 8 | Int(bytes[m + 2])
            let segmentEnd = m + 1 + length
            guard length >= 2, segmentEnd <= n else { throw CleaningError.malformedFile("segment 0x\(String(marker, radix: 16)) overruns the file") }
            if marker == 0xDA {
                // Entropy-coded data runs until the next marker that is not a stuffed byte or restart marker.
                var j = segmentEnd
                while j < n - 1 {
                    if bytes[j] == 0xFF {
                        let next = bytes[j + 1]
                        if next == 0x00 || (0xD0...0xD7).contains(next) { j += 2; continue }
                        if next == 0xFF { j += 1; continue }
                        break
                    }
                    j += 1
                }
                if j >= n - 1 { throw CleaningError.malformedFile("image data ends without an end-of-image marker") }
                segments.append(Segment(marker: marker, range: start..<j, payloadRange: (m + 3)..<segmentEnd))
                i = j
                continue
            }
            segments.append(Segment(marker: marker, range: start..<segmentEnd, payloadRange: (m + 3)..<segmentEnd))
            i = segmentEnd
        }
        throw CleaningError.malformedFile("no end-of-image marker")
    }

    static func identifier(_ data: Data, _ segment: Segment) -> Data {
        data.bytes(segment.payloadRange.lowerBound..<min(segment.payloadRange.lowerBound + 32, segment.payloadRange.upperBound))
    }

    static func isPreserved(_ segment: Segment, in data: Data) -> Bool {
        let marker = segment.marker
        switch marker {
        case 0xE0: return identifier(data, segment).starts(with: Data("JFIF\0".utf8))
        case 0xE2: return identifier(data, segment).starts(with: Data("ICC_PROFILE\0".utf8))
        case 0xEE: return identifier(data, segment).starts(with: Data("Adobe".utf8))
        case 0xE1, 0xE3...0xED, 0xEF, 0xFE: return false
        default: return true   // SOFn, DHT, DQT, DRI, DAC, SOS, RSTn…
        }
    }

    static func orientation(in data: Data, layout: Layout) -> Int? {
        for segment in layout.segments where segment.marker == 0xE1 {
            let payload = data.bytes(segment.payloadRange)
            if payload.starts(with: Data("Exif\0\0".utf8)), let value = MinimalExif.orientation(inTIFF: payload.bytes(6..<payload.count)) {
                return value
            }
        }
        return nil
    }

    static func strip(_ data: Data) throws -> (Data, [String], [String]) {
        let layout = try layout(of: data)
        var output = Data([0xFF, 0xD8])
        var dropped: [String: Int] = [:]
        var warnings: [String] = []
        let orientation = orientation(in: data, layout: layout)
        var insertedOrientation = false

        func insertOrientationIfNeeded() {
            guard !insertedOrientation else { return }
            insertedOrientation = true
            if let orientation, (2...8).contains(orientation) {
                output.append(MinimalExif.jpegAPP1(orientation: orientation))
            }
        }

        for (index, segment) in layout.segments.enumerated() {
            // EXIF orientation goes right after SOI, or after APP0 JFIF when that comes first.
            if !(index == 0 && segment.marker == 0xE0 && isPreserved(segment, in: data)) { insertOrientationIfNeeded() }
            if isPreserved(segment, in: data) {
                output.append(data.bytes(segment.range))
            } else {
                dropped[label(for: segment, in: data), default: 0] += 1
            }
            if index == 0 && segment.marker == 0xE0 && isPreserved(segment, in: data) { insertOrientationIfNeeded() }
        }
        insertOrientationIfNeeded()
        output.append(contentsOf: [0xFF, 0xD9])

        var steps: [String] = []
        if !dropped.isEmpty {
            steps.append("Removed JPEG segments: " + dropped.sorted { $0.key < $1.key }.map { "\($0.value)× \($0.key)" }.joined(separator: ", "))
        }
        if let orientation, (2...8).contains(orientation) {
            steps.append("Kept orientation (\(orientation)) in a minimal EXIF block")
        }
        if !layout.trailerRange.isEmpty {
            let trailer = data.bytes(layout.trailerRange)
            steps.append("Removed \(ByteCountFormatter.string(fromByteCount: Int64(trailer.count), countStyle: .file)) appended after the image")
            if layout.segments.contains(where: { $0.marker == 0xE2 && identifier(data, $0).starts(with: Data("MPF\0".utf8)) }) {
                warnings.append("Secondary images stored after the main image (MPF: e.g. HDR gain map or depth map) were removed. The primary image is unchanged, but HDR displays may show it as standard dynamic range.")
            }
        }
        return (output, steps, warnings)
    }

    static func label(for segment: Segment, in data: Data) -> String {
        let id = identifier(data, segment)
        switch segment.marker {
        case 0xFE: return "COM"
        case 0xE1:
            if id.starts(with: Data("Exif".utf8)) { return "APP1 EXIF" }
            if id.starts(with: Data("http://ns.adobe.com/xmp/extension/".utf8)) { return "APP1 Extended XMP" }
            if id.starts(with: Data("http://ns.adobe.com/xap/1.0/".utf8)) { return "APP1 XMP" }
            return "APP1"
        case 0xE2:
            if id.starts(with: Data("MPF".utf8)) { return "APP2 MPF" }
            if id.starts(with: Data("FPXR".utf8)) { return "APP2 FlashPix" }
            return "APP2"
        case 0xEB: return "APP11 JUMBF/C2PA"
        case 0xED: return "APP13 IPTC/Photoshop"
        default: return "APP\(Int(segment.marker) - 0xE0)"
        }
    }

    /// Structural findings that complement ExifTool: C2PA containers, comments, unknown segments and trailers.
    static func scan(_ data: Data) -> [MetadataItem] {
        guard let layout = try? layout(of: data) else { return [] }
        var items: [MetadataItem] = []
        var jumbfBytes = 0
        for segment in layout.segments where !isPreserved(segment, in: data) {
            let payload = data.bytes(segment.payloadRange)
            switch segment.marker {
            case 0xEB:
                jumbfBytes += payload.count
            case 0xFE:
                let text = payload.looseText.trimmingCharacters(in: .controlCharacters)
                var item = MetadataItem(category: .comments, group: "JPEG:COM", name: "Comment", value: text, source: .structure)
                if let reason = AISignatures.aiReason(name: "Comment", value: text) {
                    item.category = .aiGeneration
                    item.reason = reason
                }
                items.append(item)
            case 0xE1, 0xE2, 0xED:
                break // EXIF, XMP, ICC, MPF and IPTC are reported in detail by ExifTool.
            default:
                var item = MetadataItem(category: .other, group: "JPEG:\(label(for: segment, in: data))",
                                        name: "Application segment", value: "\(payload.count) bytes", source: .structure)
                if let marker = payload.firstMarker(of: AISignatures.c2paByteMarkers) {
                    item.category = .contentCredentials
                    item.reason = "Contains C2PA marker “\(marker)”"
                }
                items.append(item)
            }
        }
        if jumbfBytes > 0 {
            items.append(MetadataItem(category: .contentCredentials, group: "JPEG:APP11", name: "C2PA manifest store (JUMBF)",
                                      value: ByteCountFormatter.string(fromByteCount: Int64(jumbfBytes), countStyle: .file),
                                      source: .structure, reason: "JUMBF segments carry C2PA manifests"))
        }
        if !layout.trailerRange.isEmpty {
            let trailer = data.bytes(layout.trailerRange)
            var item = MetadataItem(category: .thumbnails, group: "JPEG:Trailer", name: "Data after end of image",
                                    value: ByteCountFormatter.string(fromByteCount: Int64(trailer.count), countStyle: .file),
                                    source: .structure)
            if trailer.range(of: Data("PhotoEditor_Re_Edit_Data".utf8)) != nil || trailer.range(of: Data("genAIType".utf8)) != nil {
                item.category = .aiGeneration
                item.reason = "Samsung Galaxy AI editing record"
            } else if let marker = trailer.firstMarker(of: AISignatures.c2paByteMarkers) {
                item.category = .contentCredentials
                item.reason = "Contains C2PA marker “\(marker)”"
            }
            items.append(item)
        }
        return items
    }
}

//
//  MediaFormat.swift
//  Metadata Wash
//

import Foundation
import UniformTypeIdentifiers

/// A media container the app knows how to inspect and clean.
///
/// The format is detected from the file's leading bytes, not its extension, so a
/// mislabeled file is still processed with the right backend.
nonisolated enum MediaFormat: String, Sendable, CaseIterable, Codable {
    case jpeg, png, webp, tiff, heic, avif, gif
    case mp4, mov, m4v, webm, mkv

    enum Kind: Sendable { case image, video }

    var kind: Kind {
        switch self {
        case .jpeg, .png, .webp, .tiff, .heic, .avif, .gif: .image
        case .mp4, .mov, .m4v, .webm, .mkv: .video
        }
    }

    var displayName: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .webp: "WebP"
        case .tiff: "TIFF"
        case .heic: "HEIC"
        case .avif: "AVIF"
        case .gif: "GIF"
        case .mp4: "MP4"
        case .mov: "QuickTime"
        case .m4v: "M4V"
        case .webm: "WebM"
        case .mkv: "Matroska"
        }
    }

    /// Extension used for the cleaned copy.
    var preferredExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .tiff: "tiff"
        default: rawValue
        }
    }

    var mimeType: String {
        switch self {
        case .jpeg: "image/jpeg"
        case .png: "image/png"
        case .webp: "image/webp"
        case .tiff: "image/tiff"
        case .heic: "image/heic"
        case .avif: "image/avif"
        case .gif: "image/gif"
        case .mp4: "video/mp4"
        case .mov: "video/quicktime"
        case .m4v: "video/x-m4v"
        case .webm: "video/webm"
        case .mkv: "video/x-matroska"
        }
    }

    /// ISO base media file format (MP4 family, HEIF, AVIF).
    var isBMFF: Bool {
        switch self {
        case .heic, .avif, .mp4, .mov, .m4v: true
        default: false
        }
    }

    /// Content types offered in the open panel.
    static var openableContentTypes: [UTType] {
        var types: [UTType] = [.jpeg, .png, .webP, .tiff, .heic, .gif, .mpeg4Movie, .quickTimeMovie, .appleProtectedMPEG4Video]
        for ext in ["avif", "m4v", "webm", "mkv"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    /// Detects the container from its magic bytes, using the extension only to
    /// disambiguate members of the same family (e.g. MP4 vs. M4V).
    static func detect(header: Data, fileExtension: String) -> MediaFormat? {
        let b = [UInt8](header.prefix(64))
        let ext = fileExtension.lowercased()
        func ascii(_ range: Range<Int>) -> String {
            guard range.upperBound <= b.count else { return "" }
            return String(decoding: b[range], as: UTF8.self)
        }

        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if ascii(0..<4) == "RIFF", ascii(8..<12) == "WEBP" { return .webp }
        if b.starts(with: [0x49, 0x49, 0x2A, 0x00]) || b.starts(with: [0x4D, 0x4D, 0x00, 0x2A])
            || b.starts(with: [0x49, 0x49, 0x2B, 0x00]) || b.starts(with: [0x4D, 0x4D, 0x00, 0x2B]) {
            return .tiff
        }
        if ascii(0..<6) == "GIF87a" || ascii(0..<6) == "GIF89a" { return .gif }
        if b.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            // EBML: the DocType element says webm or matroska.
            return header.range(of: Data("webm".utf8)) != nil ? .webm : .mkv
        }
        if ascii(4..<8) == "ftyp" {
            let major = ascii(8..<12)
            var brands: Set<String> = [major]
            if b.count >= 16 {
                let boxSize = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
                var offset = 16
                while offset + 4 <= min(boxSize, b.count) {
                    brands.insert(ascii(offset..<offset + 4))
                    offset += 4
                }
            }
            if major == "avif" || major == "avis" { return .avif }
            if ["heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1"].contains(major) {
                return brands.contains("avif") ? .avif : .heic
            }
            if major == "qt  " { return .mov }
            if major == "M4V " || major == "M4VH" || major == "M4VP" || ext == "m4v" { return .m4v }
            if ext == "mov" { return .mov }
            return .mp4
        }
        // Old QuickTime files can start with a moov/mdat/wide/free box instead of ftyp.
        if ["moov", "mdat", "wide", "free", "skip", "pnot"].contains(ascii(4..<8)), ext == "mov" {
            return .mov
        }
        return nil
    }
}

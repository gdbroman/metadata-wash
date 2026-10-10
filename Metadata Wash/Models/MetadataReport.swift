//
//  MetadataReport.swift
//  Metadata Wash
//

import Foundation

/// Normalized metadata categories shown to the user.
///
/// Categories marked `isPreserved` describe information that is kept on purpose
/// because the file would render or play differently without it.
nonisolated enum MetadataCategory: String, Sendable, CaseIterable, Codable, Identifiable {
    case aiGeneration
    case contentCredentials
    case location
    case camera
    case timestamps
    case software
    case people
    case descriptive
    case comments
    case makerNotes
    case thumbnails
    case containerTags
    case timedMetadata
    case fileSystem
    case other
    case rendering
    case technical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aiGeneration: "AI generation data"
        case .contentCredentials: "Content Credentials (C2PA)"
        case .location: "Location"
        case .camera: "Camera & capture"
        case .timestamps: "Dates & times"
        case .software: "Software & encoder"
        case .people: "Author & rights"
        case .descriptive: "Descriptive tags (IPTC/XMP)"
        case .comments: "Comments & text"
        case .makerNotes: "Maker notes"
        case .thumbnails: "Embedded previews & extra images"
        case .containerTags: "Container & track tags"
        case .timedMetadata: "Timed metadata tracks"
        case .fileSystem: "Finder & download info"
        case .other: "Other metadata"
        case .rendering: "Color & orientation (kept)"
        case .technical: "Technical structure"
        }
    }

    var systemImage: String {
        switch self {
        case .aiGeneration: "sparkles"
        case .contentCredentials: "checkmark.seal"
        case .location: "location"
        case .camera: "camera"
        case .timestamps: "calendar"
        case .software: "app.badge"
        case .people: "person"
        case .descriptive: "tag"
        case .comments: "text.bubble"
        case .makerNotes: "wrench.and.screwdriver"
        case .thumbnails: "photo.on.rectangle"
        case .containerTags: "film"
        case .timedMetadata: "waveform.path.ecg"
        case .fileSystem: "folder"
        case .other: "ellipsis.circle"
        case .rendering: "paintpalette"
        case .technical: "gearshape"
        }
    }

    /// Kept intentionally: removing it would change how the media looks or plays.
    var isPreserved: Bool { self == .rendering }

    /// Describes the file's structure rather than adding information to it.
    var isStructural: Bool { self == .technical }

    /// Removable metadata: what the cleaner targets and what verification checks for.
    var isRemovable: Bool { !isPreserved && !isStructural }

    /// Sort order with the most sensitive categories first.
    var priority: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// Where a finding came from. Findings from independent engines corroborate each other.
nonisolated enum MetadataSource: String, Sendable, Codable {
    case exifTool = "ExifTool"
    case structure = "Structure scan"
    case c2pa = "C2PA SDK"
    case ffprobe = "FFprobe"
    case fileSystem = "File system"
}

/// Whether a finding can be removed without touching pixels or audio/video samples.
nonisolated enum Removability: Sendable, Codable, Equatable {
    case removable
    /// Embedded in the coded bitstream (e.g. encoder settings in H.264 SEI); removal needs re-encoding.
    case requiresReencoding
    /// Required by the container format; a neutral value is written instead.
    case requiredByFormat
}

/// One piece of metadata found in a file.
nonisolated struct MetadataItem: Identifiable, Sendable, Hashable, Codable {
    var id = UUID()
    var category: MetadataCategory
    /// Group as reported by the engine, e.g. "EXIF:GPS", "PNG", "QuickTime:Keys".
    var group: String
    var name: String
    var value: String
    var source: MetadataSource
    var removability: Removability = .removable
    /// Why the item was classified as AI/C2PA related, when it was.
    var reason: String?

    /// Groups the same tag regardless of the run it came from, so before/after reports can be compared.
    var signature: String { "\(group)|\(name)" }

    var displayValue: String {
        let collapsed = value.replacingOccurrences(of: "\n", with: " ⏎ ")
        return collapsed.count > 240 ? String(collapsed.prefix(240)) + "…" : collapsed
    }
}

/// Summary of the C2PA manifest store read with the C2PA SDK.
nonisolated struct C2PASummary: Sendable, Hashable, Codable {
    var isEmbedded: Bool
    var remoteManifestURL: String?
    var manifestCount: Int
    var claimGenerators: [String]
    var title: String?
    var issuer: String?
    var signedAt: String?
    var actions: [String]
    var digitalSourceTypes: [String]
    var validationState: String?
    var validationIssues: [String]

    var indicatesAIGeneration: Bool {
        digitalSourceTypes.contains { $0.localizedCaseInsensitiveContains("trainedAlgorithmicMedia") }
    }
}

/// State of the C2PA check for a file.
nonisolated enum C2PAStatus: Sendable, Hashable, Codable {
    case notChecked(reason: String)
    case none
    case present(C2PASummary)
    /// C2PA data was found but the SDK could not parse it (still counts as present).
    case unreadable(reason: String)

    var isPresent: Bool {
        switch self {
        case .present, .unreadable: true
        default: false
        }
    }
}

/// Normalized result of inspecting a file with every available engine.
nonisolated struct MetadataReport: Sendable, Codable {
    var format: MediaFormat
    var fileSize: Int64
    var items: [MetadataItem]
    var c2pa: C2PAStatus
    /// Engines that could not run, so the report may be incomplete.
    var engineNotes: [String]

    var removableItems: [MetadataItem] {
        items.filter { $0.category.isRemovable && $0.removability == .removable }
    }

    var residualItems: [MetadataItem] {
        items.filter { $0.category.isRemovable && $0.removability != .removable }
    }

    var preservedItems: [MetadataItem] {
        items.filter { $0.category.isPreserved }
    }

    var removableCategories: Set<MetadataCategory> {
        Set(removableItems.map(\.category))
    }

    var hasAIMetadata: Bool {
        items.contains { $0.category == .aiGeneration }
            || {
                if case .present(let summary) = c2pa { return summary.indicatesAIGeneration }
                return false
            }()
    }

    var hasContentCredentials: Bool {
        c2pa.isPresent || items.contains { $0.category == .contentCredentials }
    }

    func items(in category: MetadataCategory) -> [MetadataItem] {
        items.filter { $0.category == category }
    }

    /// Categories present in the report, most sensitive first.
    var categories: [MetadataCategory] {
        Set(items.map(\.category)).sorted { $0.priority < $1.priority }
    }
}

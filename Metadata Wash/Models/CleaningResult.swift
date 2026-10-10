//
//  CleaningResult.swift
//  Metadata Wash
//

import Foundation

/// Outcome of cleaning one file, based on an independent inspection of the output.
nonisolated struct CleaningResult: Sendable {
    nonisolated enum Status: Sendable, Equatable {
        /// The output was re-inspected and no recognized removable metadata remains.
        case cleaned
        /// The output was written, but recognized removable metadata is still present.
        case partiallyCleaned
        /// The output was written, but some verification engines were unavailable.
        case unverified
        case failed(String)
        case unsupported(String)
        case cancelled
    }

    var status: Status
    var outputURL: URL?
    /// Categories present before cleaning and absent after.
    var removedCategories: [MetadataCategory]
    /// Removable metadata the verification pass still found.
    var remainingItems: [MetadataItem]
    /// Metadata that cannot be removed losslessly (e.g. encoder strings in the video bitstream).
    var residualItems: [MetadataItem]
    /// Rendering information kept on purpose (ICC profile, orientation, HDR signaling…).
    var preservedItems: [MetadataItem]
    /// What each processing stage did, in order.
    var steps: [String]
    var warnings: [String]
    var verification: MetadataReport?
    /// True when pixels or samples were decoded and re-encoded. The current pipeline never does this.
    var reencodedMedia: Bool = false

    static func failure(_ message: String, steps: [String] = [], warnings: [String] = []) -> CleaningResult {
        CleaningResult(status: .failed(message), outputURL: nil, removedCategories: [], remainingItems: [],
                       residualItems: [], preservedItems: [], steps: steps, warnings: warnings, verification: nil)
    }

    static func unsupported(_ message: String) -> CleaningResult {
        CleaningResult(status: .unsupported(message), outputURL: nil, removedCategories: [], remainingItems: [],
                       residualItems: [], preservedItems: [], steps: [], warnings: [], verification: nil)
    }

    static var cancelled: CleaningResult {
        CleaningResult(status: .cancelled, outputURL: nil, removedCategories: [], remainingItems: [],
                       residualItems: [], preservedItems: [], steps: [], warnings: [], verification: nil)
    }
}

extension CleaningResult.Status {
    nonisolated var title: String {
        switch self {
        case .cleaned: "Supported metadata removed"
        case .partiallyCleaned: "Partially cleaned"
        case .unverified: "Cleaned, verification limited"
        case .failed: "Failed"
        case .unsupported: "Unsupported"
        case .cancelled: "Cancelled"
        }
    }

    nonisolated var producedOutput: Bool {
        switch self {
        case .cleaned, .partiallyCleaned, .unverified: true
        default: false
        }
    }
}

/// Errors raised by the cleaning pipeline.
nonisolated enum CleaningError: LocalizedError {
    case engineUnavailable(String)
    case toolFailed(tool: String, status: Int32, message: String)
    case malformedFile(String)
    case unsupportedFormat(String)
    case outputMissing

    var errorDescription: String? {
        switch self {
        case .engineUnavailable(let message): message
        case .toolFailed(let tool, let status, let message):
            "\(tool) exited with status \(status)\(message.isEmpty ? "" : ": \(message)")"
        case .malformedFile(let message): "The file could not be parsed: \(message)"
        case .unsupportedFormat(let message): message
        case .outputMissing: "The cleaning engine did not produce an output file."
        }
    }
}

//
//  MediaItem.swift
//  Metadata Wash
//

import AppKit
import Foundation
import Observation

/// One file in the queue and everything known about it.
@Observable
final class MediaItem: Identifiable {
    enum Phase: Equatable {
        case inspecting
        case ready
        case cleaning
        case finished
        case failed(String)
    }

    let id = UUID()
    let sourceURL: URL
    var format: MediaFormat?
    var phase: Phase = .inspecting
    var report: MetadataReport?
    var result: CleaningResult?
    var thumbnail: NSImage?

    /// Private workspace directory holding the working copy.
    var jobDirectory: URL?
    var workingCopy: URL?

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    var name: String { sourceURL.lastPathComponent }
    var baseName: String { sourceURL.deletingPathExtension().lastPathComponent }

    var isBusy: Bool { phase == .inspecting || phase == .cleaning }

    var canClean: Bool {
        guard report != nil, workingCopy != nil else { return false }
        return phase == .ready || phase == .finished
    }

    /// Short status line for the list.
    var statusText: String {
        switch phase {
        case .inspecting: return "Inspecting…"
        case .cleaning: return "Cleaning…"
        case .failed(let message): return message
        case .ready:
            guard let report else { return "" }
            let count = report.removableItems.count + (report.c2pa.isPresent && !report.items.contains { $0.category == .contentCredentials } ? 1 : 0)
            return count == 0 ? "No removable metadata found" : "\(count) removable item\(count == 1 ? "" : "s")"
        case .finished:
            return result?.status.title ?? ""
        }
    }
}

//
//  MetadataCleaner.swift
//  Metadata Wash
//

import Foundation

/// Coordinates cleaning, independent verification and export of one file.
///
/// A successful engine run is never taken as proof: the output is re-inspected
/// with every engine, a targeted second pass removes anything ExifTool can still
/// delete, and the reported status reflects what the final inspection found.
nonisolated struct MetadataCleaner: Sendable {
    let inspector: MetadataInspector
    let images: ImageCleaningService
    let videos: VideoCleaningService
    /// Future pixel-level stages (e.g. invisible watermark detection) plug in here.
    /// None ship today: the cleaner never modifies pixels or frames.
    let pixelStages: [any PixelAnalysisStage]

    init(tools: BundledTools = .shared, runner: ExternalToolRunner, pixelStages: [any PixelAnalysisStage] = []) {
        inspector = MetadataInspector(tools: tools, runner: runner)
        images = ImageCleaningService(exifTool: inspector.exifTool)
        videos = VideoCleaningService(ffmpeg: inspector.ffmpeg, exifTool: inspector.exifTool)
        self.pixelStages = pixelStages
    }

    /// - Parameters:
    ///   - input: the workspace copy of the original.
    ///   - before: the report produced when the file was added.
    ///   - destination: where to write the cleaned copy (the caller holds access to it).
    ///   - baseName: file name of the original, without extension.
    @concurrent
    func clean(_ input: URL, format: MediaFormat, before: MetadataReport, destination: URL, baseName: String) async -> CleaningResult {
        let directory = input.deletingLastPathComponent()
        var steps: [String] = []
        var warnings: [String] = []
        do {
            let cleanedFile: URL
            switch format.kind {
            case .image:
                let output = try await images.clean(input, format: format, in: directory)
                (cleanedFile, steps, warnings) = (output.file, output.steps, output.warnings)
            case .video:
                let output = try await videos.clean(input, format: format, in: directory)
                (cleanedFile, steps, warnings) = (output.file, output.steps, output.warnings)
            }
            ExtendedAttributes.removeAll(at: cleanedFile)
            try Task.checkCancellation()

            // Independent verification of the output.
            var after = try await inspector.inspect(cleanedFile, format: format, attributesOf: cleanedFile)
            let leftovers = after.removableItems.filter { $0.source == .exifTool }
            if !leftovers.isEmpty, inspector.exifTool.isAvailable {
                warnings += try await inspector.exifTool.delete(tags: leftovers, in: cleanedFile)
                if format.isBMFF { steps += try BMFFContainer.neutralizeProvenanceBoxes(at: cleanedFile) }
                ExtendedAttributes.removeAll(at: cleanedFile)
                after = try await inspector.inspect(cleanedFile, format: format, attributesOf: cleanedFile)
                steps.append("Second pass removed \(max(0, leftovers.count - after.removableItems.filter { $0.source == .exifTool }.count)) leftover tag(s)")
            }
            try Task.checkCancellation()

            let exported = try export(cleanedFile, to: destination, baseName: baseName, format: format)
            ExtendedAttributes.removeAll(at: exported)
            steps.append("Saved \(exported.lastPathComponent)")

            for stage in pixelStages {
                warnings += await stage.notes(for: exported, format: format)
            }
            return Self.result(before: before, after: after, output: exported, steps: steps, warnings: warnings)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(error.localizedDescription, steps: steps, warnings: warnings)
        }
    }

    static func result(before: MetadataReport, after: MetadataReport, output: URL, steps: [String], warnings: [String]) -> CleaningResult {
        var warnings = warnings
        let remaining = after.removableItems
        let removed = before.removableCategories.subtracting(after.removableCategories)
            .union(before.c2pa.isPresent && !after.c2pa.isPresent ? [.contentCredentials] : [])
            .sorted { $0.priority < $1.priority }

        let status: CleaningResult.Status
        if !remaining.isEmpty || after.c2pa.isPresent {
            status = .partiallyCleaned
        } else if !after.engineNotes.isEmpty {
            status = .unverified
            warnings.append("Verification was limited: " + after.engineNotes.joined(separator: "; "))
        } else {
            status = .cleaned
        }

        if before.hasContentCredentials {
            warnings.append("Embedded Content Credentials were removed, but services using “durable” credentials can still look them up from an invisible watermark or fingerprint of the pixels.")
        }
        if before.hasAIMetadata || before.hasContentCredentials {
            warnings.append("Invisible watermarks embedded in the pixels or frames (e.g. SynthID) are not metadata and are not detected or removed.")
        }
        return CleaningResult(status: status, outputURL: output, removedCategories: removed, remainingItems: remaining,
                              residualItems: after.residualItems, preservedItems: after.preservedItems,
                              steps: steps, warnings: warnings.uniqued(), verification: after)
    }

    /// Copies the cleaned file to the destination under a name that does not overwrite anything.
    private func export(_ file: URL, to destination: URL, baseName: String, format: MediaFormat) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let ext = format.preferredExtension
        var candidate = destination.appending(path: "\(baseName)-clean.\(ext)")
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = destination.appending(path: "\(baseName)-clean-\(counter).\(ext)")
            counter += 1
        }
        try fm.copyItem(at: file, to: candidate)
        return candidate
    }
}

/// Extension point for pixel-level analysis (e.g. invisible-watermark detectors).
///
/// Stages may only *report*; metadata cleaning never alters pixels or frames, and
/// heavyweight ML models are intentionally not part of this app.
nonisolated protocol PixelAnalysisStage: Sendable {
    func notes(for file: URL, format: MediaFormat) async -> [String]
}

//
//  ImageCleaningService.swift
//  Metadata Wash
//

import Foundation

/// Removes metadata from still images without re-encoding pixels.
///
/// | Format     | Primary engine                         | Fallback          |
/// |------------|----------------------------------------|-------------------|
/// | JPEG       | Native segment filter                  | ExifTool          |
/// | PNG        | Native chunk allow-list                | ExifTool          |
/// | WebP       | Native RIFF chunk filter               | ExifTool          |
/// | TIFF, GIF  | ExifTool                               | —                 |
/// | HEIC, AVIF | ExifTool + native C2PA box removal     | —                 |
///
/// The native filters are used first for JPEG/PNG/WebP because they keep color
/// chunks (gAMA, cHRM, sRGB, cICP…) that ExifTool's `-all=` would delete, and
/// because their output is easy to reason about: bytes are either copied or dropped.
nonisolated struct ImageCleaningService: Sendable {
    nonisolated struct Output: Sendable {
        var file: URL
        var steps: [String]
        var warnings: [String]
    }

    let exifTool: ExifToolService

    @concurrent
    func clean(_ input: URL, format: MediaFormat, in directory: URL) async throws -> Output {
        let output = directory.appending(path: "cleaned.\(format.preferredExtension)")
        try? FileManager.default.removeItem(at: output)

        switch format {
        case .jpeg, .png, .webp:
            do {
                let data = try Data(contentsOf: input)
                try Task.checkCancellation()
                var steps: [String]
                var warnings: [String] = []
                let cleaned: Data
                switch format {
                case .jpeg: (cleaned, steps, warnings) = try JPEGContainer.strip(data)
                case .png: (cleaned, steps) = try PNGContainer.strip(data)
                default: (cleaned, steps) = try WebPContainer.strip(data)
                }
                try cleaned.write(to: output, options: .atomic)
                steps.insert("Native \(format.displayName) filter: image data copied byte-for-byte", at: 0)
                return Output(file: output, steps: steps, warnings: warnings)
            } catch let error as CleaningError {
                guard exifTool.isAvailable else { throw error }
                var result = try await cleanWithExifTool(input, to: output, format: format)
                result.warnings.insert("The native \(format.displayName) parser could not read this file (\(error.localizedDescription)); ExifTool was used instead.", at: 0)
                if format == .png {
                    result.warnings.append("ExifTool removes PNG gamma/chromaticity chunks; colors may differ slightly in apps that rely on them.")
                }
                return result
            }

        case .tiff, .gif, .heic, .avif:
            guard exifTool.isAvailable else {
                throw CleaningError.engineUnavailable("Cleaning \(format.displayName) requires ExifTool, which is not bundled with this build.")
            }
            var result = try await cleanWithExifTool(input, to: output, format: format)
            if format.isBMFF {
                result.steps += try BMFFContainer.neutralizeProvenanceBoxes(at: output)
            }
            return result

        default:
            throw CleaningError.unsupportedFormat("\(format.displayName) is not an image format.")
        }
    }

    private func cleanWithExifTool(_ input: URL, to output: URL, format: MediaFormat) async throws -> Output {
        // HEIF orientation lives in the irot/imir item properties, which ExifTool keeps.
        let orientation = format.isBMFF ? nil : try? await exifTool.orientation(at: input)
        let warnings = try await exifTool.removeAll(from: input, to: output, keepICC: true, orientation: orientation)
        var steps = ["ExifTool removed all writable metadata; ICC profile restored"]
        if let orientation, (2...8).contains(orientation) { steps.append("Kept orientation (\(orientation))") }
        return Output(file: output, steps: steps, warnings: warnings)
    }
}

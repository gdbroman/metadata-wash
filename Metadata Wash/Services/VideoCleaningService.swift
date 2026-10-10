//
//  VideoCleaningService.swift
//  Metadata Wash
//

import Foundation

/// Removes container and stream metadata from videos without re-encoding.
///
/// Primary path: FFmpeg stream-copy remux in bit-exact mode, which rebuilds the
/// container from the coded samples only — dropping global/stream tags, chapters,
/// data tracks, cover art and vendor boxes (including C2PA `uuid` boxes) while
/// keeping rotation, HDR/color signaling, timing and every audio/video sample.
///
/// Fallback for MP4/MOV/M4V (FFmpeg missing or unable to remux): in-place
/// neutralization of metadata boxes, followed by ExifTool for anything left.
nonisolated struct VideoCleaningService: Sendable {
    nonisolated struct Output: Sendable {
        var file: URL
        var steps: [String]
        var warnings: [String]
    }

    let ffmpeg: FFmpegService
    let exifTool: ExifToolService

    @concurrent
    func clean(_ input: URL, format: MediaFormat, in directory: URL) async throws -> Output {
        let output = directory.appending(path: "cleaned.\(format.preferredExtension)")
        var warnings: [String] = []

        if ffmpeg.isAvailable {
            let probe = try? await ffmpeg.probe(input)
            if let probe {
                let dropped = probe.streams.filter { $0.codecType == "data" || $0.codecType == "attachment" || $0.isAttachedPicture }
                if !dropped.isEmpty {
                    warnings.append("Removed \(dropped.count) non-audio/video track(s) (timed metadata, timecode, attachments or cover art).")
                }
            }
            do {
                var steps = try await ffmpeg.remux(input, to: output, format: format, probe: probe, includeSubtitles: true)
                if format.isBMFF { steps += try BMFFContainer.neutralizeProvenanceBoxes(at: output) }
                return Output(file: output, steps: steps, warnings: warnings)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let hasSubtitles = probe?.streams.contains { $0.codecType == "subtitle" } ?? true
                if hasSubtitles {
                    do {
                        var steps = try await ffmpeg.remux(input, to: output, format: format, probe: probe, includeSubtitles: false)
                        if format.isBMFF { steps += try BMFFContainer.neutralizeProvenanceBoxes(at: output) }
                        warnings.append("Subtitle tracks could not be stream-copied into \(format.displayName) and were left out.")
                        return Output(file: output, steps: steps, warnings: warnings)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        warnings.append("FFmpeg could not remux this file (\(error.localizedDescription)).")
                    }
                } else {
                    warnings.append("FFmpeg could not remux this file (\(error.localizedDescription)).")
                }
            }
        }

        guard format.isBMFF else {
            throw CleaningError.engineUnavailable("Cleaning \(format.displayName) requires the bundled FFmpeg engine.")
        }
        return try await cleanInPlace(input, output: output, warnings: warnings)
    }

    private func cleanInPlace(_ input: URL, output: URL, warnings: [String]) async throws -> Output {
        var warnings = warnings
        let staged = output.deletingLastPathComponent().appending(path: "staged.\(output.pathExtension)")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: input, to: staged)
        var steps = try BMFFContainer.neutralizeProvenanceBoxes(at: staged)
        steps += try BMFFContainer.neutralizeMovieMetadata(at: staged)
        try Task.checkCancellation()
        if exifTool.isAvailable {
            warnings += try await exifTool.removeAll(from: staged, to: output, keepICC: false, orientation: nil)
            steps.append("ExifTool removed remaining writable QuickTime/XMP metadata")
            try? FileManager.default.removeItem(at: staged)
        } else {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: staged, to: output)
        }
        warnings.append("Used the in-place fallback instead of an FFmpeg remux; data tracks were not removed.")
        return Output(file: output, steps: steps, warnings: warnings)
    }
}

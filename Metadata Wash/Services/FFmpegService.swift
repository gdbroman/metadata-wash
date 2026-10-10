//
//  FFmpegService.swift
//  Metadata Wash
//

import Foundation

/// Wraps the bundled FFmpeg/FFprobe for container- and stream-level video metadata.
nonisolated struct FFmpegService: Sendable {
    nonisolated struct Stream: Sendable {
        var index: Int
        var codecType: String
        var codecName: String
        var isAttachedPicture: Bool
        var language: String?
        var tags: [String: String]
    }

    nonisolated struct Probe: Sendable {
        var streams: [Stream]
        var formatTags: [String: String]
        var chapterCount: Int
    }

    let tools: BundledTools
    let runner: ExternalToolRunner

    var isAvailable: Bool { tools.hasFFmpeg }

    func probe(_ url: URL) async throws -> Probe {
        guard let ffprobe = tools.ffprobe else { throw CleaningError.engineUnavailable("FFprobe is not bundled with this build.") }
        let output = try await runner.run(ffprobe, arguments: [
            "-v", "error", "-print_format", "json", "-show_streams", "-show_format", "-show_chapters", "--", url.path,
        ])
        guard output.succeeded, let json = try JSONSerialization.jsonObject(with: output.stdout) as? [String: Any] else {
            throw CleaningError.toolFailed(tool: "FFprobe", status: output.status, message: output.stderrString.trimmed)
        }
        let streams = (json["streams"] as? [[String: Any]] ?? []).map { s -> Stream in
            let tags = (s["tags"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
            let disposition = s["disposition"] as? [String: Any] ?? [:]
            return Stream(index: s["index"] as? Int ?? 0,
                          codecType: s["codec_type"] as? String ?? "unknown",
                          codecName: s["codec_name"] as? String ?? (s["codec_tag_string"] as? String ?? "unknown"),
                          isAttachedPicture: (disposition["attached_pic"] as? Int ?? 0) == 1,
                          language: tags["language"].flatMap { $0 == "und" ? nil : $0 },
                          tags: tags)
        }
        let format = json["format"] as? [String: Any] ?? [:]
        let formatTags = (format["tags"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
        return Probe(streams: streams, formatTags: formatTags, chapterCount: (json["chapters"] as? [Any])?.count ?? 0)
    }

    /// Findings FFprobe can see that ExifTool reports poorly: per-stream tags, data tracks, chapters, attachments.
    static func findings(from probe: Probe) -> [MetadataItem] {
        var items: [MetadataItem] = []
        let ignoredTags: Set<String> = ["language", "handler_name", "vendor_id", "major_brand", "minor_version",
                                        "compatible_brands", "creation_time", "encoder", "DURATION", "duration"]
        for stream in probe.streams {
            if stream.codecType == "data" || stream.codecType == "attachment" || stream.isAttachedPicture {
                let category: MetadataCategory = stream.codecType == "data" ? .timedMetadata : .thumbnails
                let label = stream.codecType == "data" ? "Data track (\(stream.tags["handler_name"] ?? stream.codecName))"
                    : stream.isAttachedPicture ? "Cover image" : "Attached file"
                items.append(MetadataItem(category: category, group: "Stream \(stream.index)", name: label,
                                          value: stream.tags["filename"] ?? stream.codecName, source: .ffprobe))
            }
            for (key, value) in stream.tags where !ignoredTags.contains(key) && !key.hasPrefix("DURATION") {
                var item = MetadataItem(category: .containerTags, group: "Stream \(stream.index) (\(stream.codecType))",
                                        name: key, value: value, source: .ffprobe)
                if let reason = AISignatures.aiReason(name: key, value: value) {
                    item.category = .aiGeneration
                    item.reason = reason
                }
                items.append(item)
            }
            if let encoder = stream.tags["encoder"] ?? stream.tags["ENCODER"], encoder != "Lavc" {
                items.append(MetadataItem(category: .software, group: "Stream \(stream.index) (\(stream.codecType))",
                                          name: "encoder", value: encoder, source: .ffprobe))
            }
        }
        if probe.chapterCount > 0 {
            items.append(MetadataItem(category: .comments, group: "Chapters", name: "Chapter markers",
                                      value: "\(probe.chapterCount)", source: .ffprobe))
        }
        return items
    }

    /// Stream-copies the media into a fresh container without global, stream or chapter metadata.
    ///
    /// - Video, audio and subtitle streams are copied bit-for-bit (no re-encoding).
    /// - Data tracks (timed GPS, timecode, vendor telemetry), attachments and cover art are dropped.
    /// - Bit-exact mode zeroes creation times and omits the muxer's encoder tag.
    /// - Track languages and dispositions are kept for correct playback.
    /// - Rotation (display matrix), HDR and color signaling are stream properties and are preserved.
    func remux(_ input: URL, to output: URL, format: MediaFormat, probe: Probe?, includeSubtitles: Bool) async throws -> [String] {
        guard let ffmpeg = tools.ffmpeg else { throw CleaningError.engineUnavailable("FFmpeg is not bundled with this build.") }
        try? FileManager.default.removeItem(at: output)

        var arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-i", input.path]
        var languageArguments: [String] = []
        var kept: [String] = []
        if let probe {
            var outputIndex = 0
            for stream in probe.streams {
                let keep = (stream.codecType == "video" && !stream.isAttachedPicture) || stream.codecType == "audio"
                    || (includeSubtitles && stream.codecType == "subtitle")
                guard keep else { continue }
                arguments += ["-map", "0:\(stream.index)"]
                if let language = stream.language {
                    languageArguments += ["-metadata:s:\(outputIndex)", "language=\(language)"]
                }
                kept.append(stream.codecType)
                outputIndex += 1
            }
            if outputIndex == 0 { throw CleaningError.unsupportedFormat("No audio or video streams were found.") }
        } else {
            arguments += ["-map", "0:V?", "-map", "0:a?"]
            if includeSubtitles { arguments += ["-map", "0:s?"] }
        }
        arguments += ["-c", "copy", "-map_metadata", "-1", "-map_metadata:s", "-1", "-map_chapters", "-1",
                      "-fflags", "+bitexact"]
        arguments += languageArguments
        switch format {
        case .mp4, .m4v: arguments += ["-f", format == .m4v ? "ipod" : "mp4"]
        case .mov: arguments += ["-f", "mov"]
        case .webm: arguments += ["-f", "webm"]
        case .mkv: arguments += ["-f", "matroska"]
        default: throw CleaningError.unsupportedFormat("\(format.displayName) is not a video container.")
        }
        arguments += [output.path]

        let result = try await runner.run(ffmpeg, arguments: arguments)
        guard result.succeeded, FileManager.default.fileExists(atPath: output.path) else {
            throw CleaningError.toolFailed(tool: "FFmpeg", status: result.status, message: Self.firstErrorLine(result.stderrString))
        }
        let counts = Dictionary(kept.map { ($0, 1) }, uniquingKeysWith: +)
        let description = counts.sorted { $0.key > $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        return ["Remuxed with stream copy (no re-encoding)" + (description.isEmpty ? "" : ": \(description)")]
    }

    private static func firstErrorLine(_ stderr: String) -> String {
        stderr.split(separator: "\n").map { String($0).trimmed }.last { !$0.isEmpty } ?? ""
    }
}

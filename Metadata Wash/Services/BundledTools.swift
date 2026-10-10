//
//  BundledTools.swift
//  Metadata Wash
//

import Foundation

/// Locates the metadata engines shipped inside the app bundle.
///
/// - ExifTool (pure Perl) lives in `Contents/Resources/exiftool` and runs on the
///   Perl interpreter that ships with macOS, so nothing needs to be installed.
/// - FFmpeg/FFprobe are universal, LGPL-only static builds in `Contents/Helpers`,
///   signed with the app sandbox `inherit` entitlement.
///
/// Tools on the user's PATH (Homebrew, MacPorts) are deliberately never used.
nonisolated struct BundledTools: Sendable {
    static let perl = URL(fileURLWithPath: "/usr/bin/perl")

    var exifToolScript: URL?
    var ffmpeg: URL?
    var ffprobe: URL?

    static let shared = BundledTools(bundle: .main)

    init(bundle: Bundle) {
        let fm = FileManager.default
        if let resources = bundle.resourceURL {
            let script = resources.appending(path: "exiftool/exiftool")
            exifToolScript = fm.fileExists(atPath: script.path) ? script : nil
        }
        let helpers = bundle.bundleURL.appending(path: "Contents/Helpers")
        let ffmpegURL = helpers.appending(path: "ffmpeg")
        let ffprobeURL = helpers.appending(path: "ffprobe")
        ffmpeg = fm.isExecutableFile(atPath: ffmpegURL.path) ? ffmpegURL : nil
        ffprobe = fm.isExecutableFile(atPath: ffprobeURL.path) ? ffprobeURL : nil
    }

    var hasExifTool: Bool {
        exifToolScript != nil && FileManager.default.isExecutableFile(atPath: Self.perl.path)
    }

    var hasFFmpeg: Bool { ffmpeg != nil }

    var exifToolVersion: String? {
        guard let script = exifToolScript else { return nil }
        let versionFile = script.deletingLastPathComponent().appending(path: "VERSION")
        return (try? String(contentsOf: versionFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

//
//  ExifToolService.swift
//  Metadata Wash
//

import Foundation

/// Wraps the bundled ExifTool for reading and removing metadata.
nonisolated struct ExifToolService: Sendable {
    nonisolated struct Tag: Sendable {
        var family0: String
        var family1: String
        var name: String
        var value: String
    }

    let tools: BundledTools
    let runner: ExternalToolRunner

    var isAvailable: Bool { tools.hasExifTool }

    /// Options placed before every invocation. `-config ""` must come first: it stops
    /// ExifTool from loading a user configuration file that could redefine tags.
    private func baseArguments() throws -> [String] {
        guard let script = tools.exifToolScript, tools.hasExifTool else {
            throw CleaningError.engineUnavailable("ExifTool is not bundled with this build.")
        }
        return [script.path, "-config", "", "-api", "LargeFileSupport=1", "-charset", "filename=UTF8"]
    }

    /// Reads every tag (duplicates, unknown tags, all groups) as JSON.
    func readTags(at url: URL) async throws -> [Tag] {
        let arguments = try baseArguments() + [
            "-json", "-a", "-u", "-G0:1", "-s", "-struct",
            "--File:all", "--System:all", "--Composite:all", "--ExifTool:all",
            "--", url.path,
        ]
        let output = try await runner.run(BundledTools.perl, arguments: arguments)
        // ExifTool exits 1 when it only had warnings; JSON is still valid.
        guard !output.stdout.isEmpty else {
            throw CleaningError.toolFailed(tool: "ExifTool", status: output.status, message: output.stderrString.trimmed)
        }
        guard let root = try JSONSerialization.jsonObject(with: output.stdout) as? [[String: Any]], let record = root.first else {
            throw CleaningError.toolFailed(tool: "ExifTool", status: output.status, message: "unreadable JSON output")
        }
        var tags: [Tag] = []
        for (key, value) in record where key != "SourceFile" {
            // Keys are "Family0:Family1:Tag", or "Group:Tag" when both families are the same.
            let parts = key.split(separator: ":", maxSplits: 2).map(String.init)
            switch parts.count {
            case 3: tags.append(Tag(family0: parts[0], family1: parts[1], name: parts[2], value: Self.stringify(value)))
            case 2: tags.append(Tag(family0: parts[0], family1: parts[0], name: parts[1], value: Self.stringify(value)))
            default: continue
            }
        }
        return tags.sorted { ($0.family0, $0.family1, $0.name) < ($1.family0, $1.family1, $1.name) }
    }

    /// Numeric EXIF orientation (1–8), if present.
    func orientation(at url: URL) async throws -> Int? {
        let output = try await runner.run(BundledTools.perl, arguments: try baseArguments() + ["-s3", "-n", "-EXIF:Orientation", "--", url.path])
        return Int(output.stdoutString.trimmed)
    }

    /// Writes a copy of `input` to `output` with all writable metadata removed.
    ///
    /// - Parameters:
    ///   - keepICC: copy the ICC profile back, since it defines how colors render.
    ///   - orientation: EXIF orientation to write back (only when not the default).
    func removeAll(from input: URL, to output: URL, keepICC: Bool, orientation: Int?) async throws -> [String] {
        try? FileManager.default.removeItem(at: output)
        var arguments = try baseArguments() + ["-m", "-all="]
        if keepICC {
            arguments += ["-tagsfromfile", "@", "-ICC_Profile"]
        }
        if let orientation, (2...8).contains(orientation) {
            arguments += ["-EXIF:Orientation#=\(orientation)"]
        }
        arguments += ["-o", output.path, "--", input.path]
        let result = try await runner.run(BundledTools.perl, arguments: arguments)
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw CleaningError.toolFailed(tool: "ExifTool", status: result.status, message: result.stderrString.trimmed)
        }
        return Self.warnings(from: result.stderrString)
    }

    /// Deletes specific tags in place (used for leftovers such as IFD0 tags in TIFF).
    func delete(tags: [MetadataItem], in file: URL) async throws -> [String] {
        let assignments = Set(tags.compactMap { item -> String? in
            guard item.source == .exifTool else { return nil }
            let family1 = item.group.split(separator: ":").last.map(String.init) ?? item.group
            return "-\(family1):\(item.name)="
        })
        guard !assignments.isEmpty else { return [] }
        let arguments = try baseArguments() + ["-m", "-overwrite_original"] + assignments.sorted() + ["--", file.path]
        let result = try await runner.run(BundledTools.perl, arguments: arguments)
        return Self.warnings(from: result.stderrString)
    }

    private static func warnings(from stderr: String) -> [String] {
        stderr.split(separator: "\n")
            .map { String($0).trimmed }
            .filter { !$0.isEmpty && !$0.contains("ICC_Profile deleted") && !$0.contains("files updated") && !$0.contains("files created") }
            .map { $0.replacingOccurrences(of: #" - /.*$"#, with: "", options: .regularExpression) }
    }

    private static func stringify(_ value: Any) -> String {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        case let array as [Any]: return array.map(stringify).joined(separator: ", ")
        case let dict as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) {
                return String(decoding: data, as: UTF8.self)
            }
            return "\(dict)"
        default: return "\(value)"
        }
    }
}

extension String {
    nonisolated var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

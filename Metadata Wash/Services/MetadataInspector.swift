//
//  MetadataInspector.swift
//  Metadata Wash
//

import Foundation

/// Reads a file with every available engine and merges the results into one report.
///
/// Engines are independent on purpose: ExifTool covers the broadest set of tags,
/// the native structure scanners look at raw chunks/segments/boxes (catching C2PA
/// containers and AI text even where tag parsers disagree), FFprobe covers stream
/// level video tags, and the C2PA SDK validates Content Credentials. The same
/// inspector is used to verify cleaned output.
nonisolated struct MetadataInspector: Sendable {
    let tools: BundledTools
    let exifTool: ExifToolService
    let ffmpeg: FFmpegService

    init(tools: BundledTools = .shared, runner: ExternalToolRunner) {
        self.tools = tools
        self.exifTool = ExifToolService(tools: tools, runner: runner)
        self.ffmpeg = FFmpegService(tools: tools, runner: runner)
    }

    /// Detects the media format from the file's leading bytes.
    static func detectFormat(of url: URL) throws -> MediaFormat {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 4096) ?? Data()
        guard let format = MediaFormat.detect(header: header, fileExtension: url.pathExtension) else {
            throw CleaningError.unsupportedFormat("“\(url.lastPathComponent)” is not a supported image or video format.")
        }
        return format
    }

    /// Inspects `file` (a copy inside the workspace).
    /// - Parameter attributesOf: file whose extended attributes should be reported (the user's original, or the output).
    @concurrent
    func inspect(_ file: URL, format: MediaFormat, attributesOf attributeSource: URL? = nil) async throws -> MetadataReport {
        var notes: [String] = []

        async let exifResult: Result<[ExifToolService.Tag], Error> = {
            guard exifTool.isAvailable else { return .failure(CleaningError.engineUnavailable("ExifTool is not bundled with this build.")) }
            do { return .success(try await exifTool.readTags(at: file)) } catch { return .failure(error) }
        }()
        async let probeResult: Result<FFmpegService.Probe, Error>? = {
            guard format.kind == .video else { return nil }
            guard ffmpeg.isAvailable else { return .failure(CleaningError.engineUnavailable("FFprobe is not bundled with this build.")) }
            do { return .success(try await ffmpeg.probe(file)) } catch { return .failure(error) }
        }()

        let structural = Self.structuralScan(file, format: format)
        let c2pa = C2PAService.inspect(file, format: format)
        try Task.checkCancellation()

        var items: [MetadataItem] = []
        switch await exifResult {
        case .success(let tags):
            items += MetadataClassifier.classify(tags, format: format)
        case .failure(let error):
            if error is CancellationError { throw error }
            notes.append("ExifTool: \(error.localizedDescription)")
        }
        if let probe = await probeResult {
            switch probe {
            case .success(let probe): items += FFmpegService.findings(from: probe)
            case .failure(let error):
                if error is CancellationError { throw error }
                notes.append("FFprobe: \(error.localizedDescription)")
            }
        }
        items += Self.deduplicated(structural, against: items)

        if case .present(let summary) = c2pa {
            items.append(MetadataItem(category: .contentCredentials, group: "C2PA", name: "Manifest store",
                                      value: "\(summary.manifestCount) manifest(s)" + (summary.claimGenerators.first.map { " · \($0)" } ?? ""),
                                      source: .c2pa, reason: "Validated by the C2PA SDK"))
        } else if case .unreadable(let reason) = c2pa {
            items.append(MetadataItem(category: .contentCredentials, group: "C2PA", name: "Manifest (unreadable)",
                                      value: reason, source: .c2pa))
        } else if case .notChecked(let reason) = c2pa, format.kind == .image || format.isBMFF {
            notes.append("C2PA SDK: \(reason)")
        }

        if let attributeSource {
            items += ExtendedAttributes.findings(at: attributeSource)
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return MetadataReport(format: format, fileSize: size, items: items, c2pa: c2pa, engineNotes: notes)
    }

    static func structuralScan(_ file: URL, format: MediaFormat) -> [MetadataItem] {
        if format.isBMFF { return BMFFContainer.scan(file, format: format) }
        guard format.kind == .image,
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return [] }
        switch format {
        case .png: return PNGContainer.scan(data)
        case .jpeg: return JPEGContainer.scan(data)
        case .webp: return WebPContainer.scan(data)
        default: return []
        }
    }

    /// Drops structural findings that repeat an ExifTool finding (same value), keeping the richer ExifTool entry.
    static func deduplicated(_ structural: [MetadataItem], against items: [MetadataItem]) -> [MetadataItem] {
        func key(_ value: String) -> String { String(value.trimmed.prefix(80)) }
        let known = Set(items.map { key($0.value) }.filter { !$0.isEmpty })
        return structural.filter { item in
            item.removability != .removable || item.category == .contentCredentials || !known.contains(key(item.value))
        }
    }
}

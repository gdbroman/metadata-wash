//
//  PipelineTests.swift
//  Metadata WashTests
//
//  End-to-end: inspect → clean → independent verification, using the engines
//  embedded in the host app (runs inside the app sandbox).
//

import Foundation
import Testing
@testable import Metadata_Wash

@Suite(.serialized)
struct PipelineTests {
    static let fixtures = [
        "camera-ai.jpg", "c2pa-signed.jpg", "ai-generated.png", "ai-generated-c2pa.png", "ai-generated.webp",
        "ai-generated-c2pa.webp", "photo.tiff", "photo-c2pa.tiff", "photo.heic", "photo-c2pa.heic", "photo.avif",
        "photo-c2pa.avif", "tagged.mp4", "c2pa-signed.mp4", "hdr10.mov", "hdr10-c2pa.mov", "tagged.webm",
    ]

    let runner = ExternalToolRunner(workingDirectory: Workspace.shared.root)

    @Test func enginesAreBundled() {
        #expect(BundledTools.shared.hasExifTool)
        #expect(BundledTools.shared.hasFFmpeg)
        #expect(BundledTools.shared.ffprobe != nil)
    }

    @Test(arguments: fixtures)
    func cleansAndVerifies(fixture: String) async throws {
        let result = try await clean(try Fixtures.url(fixture))
        #expect(result.status == .cleaned, "\(fixture): \(result.status) remaining=\(result.remainingItems.map { "\($0.group):\($0.name)=\($0.displayValue)" })")
        let after = try #require(result.verification)
        #expect(!after.c2pa.isPresent, "\(fixture) still has C2PA")
        #expect(!after.hasAIMetadata, "\(fixture) still has AI metadata")
        #expect(after.items(in: .location).isEmpty)
        #expect(after.items(in: .camera).isEmpty)
    }

    @Test func detectsC2PAWithSDK() async throws {
        for fixture in ["c2pa-signed.jpg", "ai-generated-c2pa.png", "photo-c2pa.heic", "hdr10-c2pa.mov"] {
            let url = try Fixtures.url(fixture)
            let format = try MetadataInspector.detectFormat(of: url)
            guard case .present(let summary) = C2PAService.inspect(url, format: format) else {
                Issue.record("\(fixture): no C2PA manifest found")
                continue
            }
            if fixture != "c2pa-signed.jpg" { #expect(summary.indicatesAIGeneration, "\(fixture)") }
        }
    }

    @Test func preservesRenderingInformation() async throws {
        let jpeg = try await clean(try Fixtures.url("camera-ai.jpg"))
        let jpegAfter = try #require(jpeg.verification)
        #expect(jpegAfter.items.contains { $0.name == "Orientation" && $0.value.contains("90") })
        #expect(jpegAfter.items.contains { $0.group.hasPrefix("ICC_Profile") })

        let png = try await clean(try Fixtures.url("ai-generated.png"))
        #expect(png.verification?.items.contains { $0.group.hasPrefix("ICC_Profile") } == true)

        // Rotation lives in the track matrix and must survive the remux.
        let mp4 = try await clean(try Fixtures.url("tagged.mp4"))
        #expect(mp4.verification?.items.contains { $0.name == "MatrixStructure" && $0.value == "0 -1 0 1 0 0 0 0 1" } == true)
    }

    @Test func preservesVideoStreams() async throws {
        let ffmpeg = FFmpegService(tools: .shared, runner: runner)
        for fixture in ["tagged.mp4", "hdr10.mov", "tagged.webm"] {
            let input = try Fixtures.url(fixture)
            let result = try await clean(input)
            let output = try #require(result.outputURL)
            let before = try await ffmpeg.probe(input)
            let after = try await ffmpeg.probe(output)
            #expect(before.streams.map(\.codecName) == after.streams.map(\.codecName), "\(fixture)")
            try? FileManager.default.removeItem(at: output.deletingLastPathComponent())
        }
    }

    /// Optional real-world sample (e.g. a downloaded AI video). Set
    /// `TEST_RUNNER_METADATA_WASH_SAMPLE=/path/to/file` when running xcodebuild test.
    @Test func cleansRealWorldSample() async throws {
        guard let path = ProcessInfo.processInfo.environment["METADATA_WASH_SAMPLE"], !path.isEmpty else { return }
        let source = URL(fileURLWithPath: path)
        let format = try MetadataInspector.detectFormat(of: source)
        let job = try Workspace.shared.makeJobDirectory()
        defer { Workspace.shared.remove(job) }
        let copy = try Workspace.shared.importCopy(of: source, format: format, into: job)
        let inspector = MetadataInspector(runner: runner)
        let before = try await inspector.inspect(copy, format: format, attributesOf: source)
        print("SAMPLE BEFORE:", before.categories.map(\.title), "c2pa:", before.c2pa)
        let destination = job.appending(path: "out")
        let result = await MetadataCleaner(runner: runner).clean(copy, format: format, before: before, destination: destination,
                                                                 baseName: source.deletingPathExtension().lastPathComponent)
        print("SAMPLE RESULT:", result.status, "removed:", result.removedCategories.map(\.title))
        print("SAMPLE STEPS:", result.steps, "WARNINGS:", result.warnings)
        print("SAMPLE REMAINING:", result.remainingItems.map { "\($0.group):\($0.name)=\($0.displayValue)" })
        print("SAMPLE RESIDUAL:", result.residualItems.map { "\($0.group):\($0.name)=\($0.displayValue)" })
        #expect(before.c2pa.isPresent)
        #expect(result.status == .cleaned)
        #expect(result.verification?.c2pa.isPresent == false)
        #expect(result.verification?.items(in: .fileSystem).isEmpty == true)
    }

    private func clean(_ fixture: URL) async throws -> CleaningResult {
        let format = try MetadataInspector.detectFormat(of: fixture)
        let job = try Workspace.shared.makeJobDirectory()
        let copy = try Workspace.shared.importCopy(of: fixture, format: format, into: job)
        let before = try await MetadataInspector(runner: runner).inspect(copy, format: format)
        #expect(!before.removableItems.isEmpty, "\(fixture.lastPathComponent) fixture has no metadata to remove")
        return await MetadataCleaner(runner: runner).clean(copy, format: format, before: before,
                                                           destination: job.appending(path: "out"),
                                                           baseName: fixture.deletingPathExtension().lastPathComponent)
    }
}

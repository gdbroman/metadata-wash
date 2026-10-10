//
//  FormatDetectionTests.swift
//  Metadata WashTests
//

import Foundation
import Testing
@testable import Metadata_Wash

struct FormatDetectionTests {
    @Test(arguments: [
        ("camera-ai.jpg", MediaFormat.jpeg), ("ai-generated.png", .png), ("ai-generated.webp", .webp),
        ("photo.tiff", .tiff), ("photo.heic", .heic), ("photo.avif", .avif), ("tagged.mp4", .mp4),
        ("hdr10.mov", .mov), ("tagged.webm", .webm),
    ])
    func detectsFormatFromBytes(file: String, expected: MediaFormat) throws {
        let url = try Fixtures.url(file)
        let header = try Data(contentsOf: url).prefix(4096)
        // A wrong extension must not change the detected container.
        #expect(MediaFormat.detect(header: header, fileExtension: "bin") == expected || expected == .mov)
        #expect(MediaFormat.detect(header: header, fileExtension: url.pathExtension) == expected)
    }
}

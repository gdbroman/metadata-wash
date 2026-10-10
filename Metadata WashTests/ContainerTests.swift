//
//  ContainerTests.swift
//  Metadata WashTests
//
//  Native container filters must drop metadata without touching coded image data.
//

import Foundation
import Testing
@testable import Metadata_Wash

struct PNGContainerTests {
    @Test func stripsTextAndProvenanceChunksButKeepsImageAndColor() throws {
        let data = try Data(contentsOf: Fixtures.url("ai-generated.png"))
        let before = try PNGContainer.chunks(in: data).map(\.type)
        #expect(before.contains("tEXt") && before.contains("caBX") && before.contains("eXIf"))

        let (cleaned, steps) = try PNGContainer.strip(data)
        let after = try PNGContainer.chunks(in: cleaned)
        let types = Set(after.map(\.type))
        #expect(types.isSubset(of: PNGContainer.preservedChunks))
        #expect(types.contains("iCCP"))
        #expect(!steps.isEmpty)

        func idat(_ d: Data) throws -> Data {
            try PNGContainer.chunks(in: d).filter { $0.type == "IDAT" }.reduce(into: Data()) { $0.append(d.bytes($1.payloadRange)) }
        }
        #expect(try idat(cleaned) == idat(data))
    }

    @Test func scanFlagsGenerationDataAndC2PA() throws {
        let items = PNGContainer.scan(try Data(contentsOf: Fixtures.url("ai-generated.png")))
        #expect(items.contains { $0.category == .aiGeneration && $0.name == "parameters" })
        #expect(items.contains { $0.category == .aiGeneration && $0.name == "workflow" })
        #expect(items.contains { $0.category == .contentCredentials && $0.group == "PNG:caBX" })
    }
}

struct JPEGContainerTests {
    @Test func keepsScanDataAndOrientation() throws {
        let data = try Data(contentsOf: Fixtures.url("camera-ai.jpg"))
        let (cleaned, _, _) = try JPEGContainer.strip(data)
        let before = try JPEGContainer.layout(of: data)
        let after = try JPEGContainer.layout(of: cleaned)

        let scans = { (d: Data, l: JPEGContainer.Layout) in l.segments.filter { $0.marker == 0xDA }.map { d.bytes($0.range) } }
        #expect(scans(cleaned, after) == scans(data, before))
        #expect(JPEGContainer.orientation(in: cleaned, layout: after) == 6)
        #expect(!after.segments.contains { [0xEB, 0xED, 0xFE].contains($0.marker) })
        // ICC profile is kept.
        #expect(after.segments.contains { $0.marker == 0xE2 && JPEGContainer.isPreserved($0, in: cleaned) })
    }

    @Test func removesC2PAJumbf() throws {
        let data = try Data(contentsOf: Fixtures.url("c2pa-signed.jpg"))
        #expect(JPEGContainer.scan(data).contains { $0.category == .contentCredentials })
        let (cleaned, _, _) = try JPEGContainer.strip(data)
        #expect(JPEGContainer.scan(cleaned).isEmpty)
        #expect(cleaned.range(of: Data("c2pa".utf8)) == nil)
    }
}

struct WebPContainerTests {
    @Test func dropsExifAndXmpAndClearsFlags() throws {
        let data = try Data(contentsOf: Fixtures.url("ai-generated.webp"))
        let (cleaned, _) = try WebPContainer.strip(data)
        let chunks = try WebPContainer.chunks(in: cleaned)
        #expect(!chunks.contains { $0.fourCC == "XMP " || $0.fourCC == "EXIF" })
        #expect(chunks.contains { $0.fourCC == "ICCP" })
        if let vp8x = chunks.first(where: { $0.fourCC == "VP8X" }) {
            let flags = cleaned[cleaned.startIndex + vp8x.payloadRange.lowerBound]
            #expect(flags & 0x0C == 0)
        }
        #expect(cleaned.uint32LE(at: 4).map(Int.init) == cleaned.count - 8)
    }
}

struct SignatureTests {
    @Test func recognizesAIMetadata() {
        #expect(AISignatures.aiReason(name: "DigitalSourceType", value: "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia") != nil)
        #expect(AISignatures.aiReason(name: "Software", value: "Adobe Firefly") != nil)
        #expect(AISignatures.aiReason(name: "UserComment", value: "Steps: 20, Sampler: Euler a, CFG scale: 7") != nil)
        #expect(AISignatures.aiReason(name: "Encoder", value: "Google") == nil)
        #expect(AISignatures.aiReason(name: "Software", value: "Adobe Photoshop 26.0") == nil)
        // Procedural (non-trained) algorithmic media is not AI generation.
        #expect(AISignatures.aiReason(name: "DigitalSourceType", value: "http://cv.iptc.org/newscodes/digitalsourcetype/algorithmicMedia") == nil)
    }
}

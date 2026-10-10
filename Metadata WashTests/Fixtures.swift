//
//  Fixtures.swift
//  Metadata WashTests
//

import Foundation

/// Locates test media bundled with the test target (see Scripts/make-test-fixtures.py).
enum Fixtures {
    private final class Token {}

    static func url(_ name: String) throws -> URL {
        let bundle = Bundle(for: Token.self)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard let url = bundle.url(forResource: base, withExtension: ext) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        return url
    }

    /// Copies a fixture into a fresh scratch directory so tests never modify the bundle.
    static func scratchCopy(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "MetadataWashTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appending(path: name)
        try FileManager.default.copyItem(at: try url(name), to: destination)
        return destination
    }
}

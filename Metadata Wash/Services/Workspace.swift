//
//  Workspace.swift
//  Metadata Wash
//

import Darwin
import Foundation

/// Private scratch space inside the app container.
///
/// Every engine only ever reads and writes files in here: the original is cloned
/// in (an instant copy-on-write clone on APFS), processed, and the verified output
/// is copied to the destination folder. This keeps originals untouched and means
/// child processes never need access to files outside the sandbox container.
nonisolated struct Workspace: Sendable {
    let root: URL

    static let shared: Workspace = {
        let base = FileManager.default.temporaryDirectory.appending(path: "MetadataWash", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return Workspace(root: base)
    }()

    /// Creates a fresh job directory.
    func makeJobDirectory() throws -> URL {
        let dir = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Clones `source` into `directory` under an ASCII-only name.
    func importCopy(of source: URL, format: MediaFormat, into directory: URL) throws -> URL {
        let destination = directory.appending(path: "original.\(format.preferredExtension)")
        try? FileManager.default.removeItem(at: destination)
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    func remove(_ directory: URL) {
        guard directory.path.hasPrefix(root.path) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Removes leftovers from previous launches.
    func purge() {
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: item)
        }
    }
}

/// Extended attributes (Finder tags, download source URLs, quarantine info…).
nonisolated enum ExtendedAttributes {
    static func names(at url: URL) -> [String] {
        url.withUnsafeFileSystemRepresentation { path -> [String] in
            guard let path else { return [] }
            let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return [] }
            var buffer = [CChar](repeating: 0, count: size)
            let read = listxattr(path, &buffer, size, XATTR_NOFOLLOW)
            guard read > 0 else { return [] }
            return buffer[0..<read].split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        }
    }

    static func value(_ name: String, at url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            return read > 0 ? data.prefix(read) : nil
        }
    }

    private static var ownAppName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Metadata Wash"
    }

    static func removeAll(at url: URL) {
        for name in names(at: url) {
            url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return }
                _ = removexattr(path, name, XATTR_NOFOLLOW)
            }
        }
    }

    /// Human-readable findings for a file's extended attributes.
    static func findings(at url: URL) -> [MetadataItem] {
        names(at: url).compactMap { name -> MetadataItem? in
            // Provenance attributes the system adds to every file are not user metadata.
            if name == "com.apple.provenance" { return nil }
            var value = "\(value(name, at: url)?.count ?? 0) bytes"
            var label = name
            switch name {
            case "com.apple.metadata:kMDItemWhereFroms":
                label = "Downloaded from"
                if let data = self.value(name, at: url),
                   let urls = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
                    value = urls.joined(separator: ", ")
                }
            case "com.apple.quarantine":
                label = "Quarantine (download app & date)"
                if let data = self.value(name, at: url) { value = String(decoding: data, as: UTF8.self) }
                // The sandbox stamps files this app writes with its own quarantine record; sandboxed apps
                // cannot remove it, and it reveals nothing about the original file.
                if value.split(separator: ";").dropFirst(2).first.map(String.init) == ownAppName { return nil }
            case "com.apple.metadata:_kMDItemUserTags":
                label = "Finder tags"
            case "com.apple.FinderInfo":
                label = "Finder info"
            default:
                break
            }
            return MetadataItem(category: .fileSystem, group: "xattr", name: label, value: value, source: .fileSystem)
        }
    }
}

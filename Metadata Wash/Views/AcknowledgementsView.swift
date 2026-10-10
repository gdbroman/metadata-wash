//
//  AcknowledgementsView.swift
//  Metadata Wash
//

import SwiftUI

/// Shows third-party notices and the full license texts bundled with the app.
struct AcknowledgementsView: View {
    @State private var licenses: [(name: String, text: String)] = []
    private let tools = BundledTools.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(notices)
                    .textSelection(.enabled)
                Divider()
                Text("Bundled engines").font(.headline)
                Text("ExifTool \(tools.exifToolVersion ?? "not bundled") · FFmpeg \(ffmpegVersion ?? "not bundled") · C2PA Swift SDK")
                    .foregroundStyle(.secondary)
                ForEach(licenses, id: \.name) { license in
                    DisclosureGroup(license.name) {
                        Text(license.text)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(24)
            .frame(width: 640, alignment: .leading)
        }
        .frame(height: 560)
        .task { licenses = Self.loadLicenses() }
    }

    private var notices: AttributedString {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "md"),
              let markdown = try? String(contentsOf: url, encoding: .utf8),
              let attributed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString("Third-party notices are missing from this build.") }
        return attributed
    }

    private var ffmpegVersion: String? {
        guard let url = Bundle.main.resourceURL?.appending(path: "Licenses/FFmpeg-VERSION.txt") else { return nil }
        return (try? String(contentsOf: url, encoding: .utf8))?.trimmed
    }

    private static func loadLicenses() -> [(name: String, text: String)] {
        guard let folder = Bundle.main.resourceURL?.appending(path: "Licenses"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "txt" && !$0.lastPathComponent.hasSuffix("VERSION.txt") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                (try? String(contentsOf: url, encoding: .utf8)).map { (url.deletingPathExtension().lastPathComponent, $0) }
            }
    }
}

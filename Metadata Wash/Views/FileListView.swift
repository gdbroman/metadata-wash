//
//  FileListView.swift
//  Metadata Wash
//

import SwiftUI

struct FileListView: View {
    @Environment(CleaningQueue.self) private var queue
    @Binding var isImporting: Bool

    var body: some View {
        @Bindable var queue = queue
        List(selection: $queue.selection) {
            ForEach(queue.items) { item in
                FileRow(item: item)
                    .tag(item.id)
                    .contextMenu { contextMenu(for: item) }
            }
            .onDelete { offsets in
                queue.remove(Set(offsets.map { queue.items[$0].id }))
            }
        }
        .onDeleteCommand { queue.remove(queue.selection) }
        .overlay {
            if queue.items.isEmpty {
                ContentUnavailableView {
                    Label("No Files", systemImage: "tray")
                } description: {
                    Text("Drop images or videos anywhere in the window.")
                } actions: {
                    Button("Choose Files…") { isImporting = true }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            footer
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(queue.engineWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !queue.items.isEmpty {
                    Button("Clear") { queue.removeAll() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(queue.isCleaning)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var summary: String {
        let total = queue.items.count
        guard total > 0 else { return "Local processing only — nothing is uploaded." }
        let done = queue.items.filter { $0.result?.status.producedOutput == true }.count
        return done > 0 ? "\(done) of \(total) cleaned" : "\(total) file\(total == 1 ? "" : "s")"
    }

    @ViewBuilder
    private func contextMenu(for item: MediaItem) -> some View {
        if item.result?.outputURL != nil {
            Button("Show Cleaned Copy in Finder") { queue.reveal(item) }
            Button("Open Cleaned Copy") { queue.open(item) }
            Divider()
        }
        Button(item.result == nil ? "Clean" : "Clean Again") { queue.clean([item]) }
            .disabled(!item.canClean || queue.isCleaning)
        Button("Show Original in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([item.sourceURL])
        }
        Divider()
        Button("Remove from List", role: .destructive) { queue.remove([item.id]) }
            .disabled(item.phase == .cleaning)
    }
}

struct FileRow: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    if let format = item.format {
                        Text(format.displayName)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    if let report = item.report, item.result == nil {
                        FindingBadges(report: report)
                    }
                }
                HStack(spacing: 4) {
                    StatusIcon(item: item)
                    Text(item.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .draggableIfCleaned(item.result?.outputURL)
        .accessibilityElement(children: .combine)
    }

    private var thumbnail: some View {
        Group {
            if let image = item.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: item.format?.kind == .video ? "film" : "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Small markers for the most important findings.
struct FindingBadges: View {
    let report: MetadataReport

    var body: some View {
        HStack(spacing: 3) {
            if report.hasAIMetadata { badge("AI", color: .purple, help: "AI-generation metadata") }
            if report.hasContentCredentials { badge("C2PA", color: .blue, help: "Content Credentials") }
            if report.removableCategories.contains(.location) { badge("GPS", color: .red, help: "Location data") }
        }
    }

    private func badge(_ text: String, color: Color, help: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
            .help(help)
    }
}

struct StatusIcon: View {
    let item: MediaItem

    var body: some View {
        switch item.phase {
        case .inspecting, .cleaning:
            ProgressView().controlSize(.mini)
        case .ready:
            Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .finished:
            if let status = item.result?.status { StatusSymbol(status: status) }
        }
    }
}

struct StatusSymbol: View {
    let status: CleaningResult.Status

    var body: some View {
        switch status {
        case .cleaned: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .partiallyCleaned: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .unverified: Image(systemName: "checkmark.circle.badge.questionmark").foregroundStyle(.yellow)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .unsupported: Image(systemName: "nosign").foregroundStyle(.secondary)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }
}

private extension View {
    @ViewBuilder
    func draggableIfCleaned(_ url: URL?) -> some View {
        if let url { draggable(url) } else { self }
    }
}

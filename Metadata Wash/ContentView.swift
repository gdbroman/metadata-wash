//
//  ContentView.swift
//  Metadata Wash
//
//  Created by Gus on 2026-10-10.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(CleaningQueue.self) private var queue
    @State private var isImporting = false
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var queue = queue
        NavigationSplitView {
            FileListView(isImporting: $isImporting)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 460)
        } detail: {
            if let item = queue.selectedItems.first, queue.selection.count == 1 {
                ItemDetailView(item: item)
            } else if queue.items.isEmpty {
                DropZoneView(isTargeted: isDropTargeted) { isImporting = true }
            } else {
                BatchSummaryView()
            }
        }
        .toolbar { toolbarContent }
        .dropDestination(for: URL.self) { urls, _ in
            queue.add(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .onOpenURL { url in
            // Files opened with "Open With", dropped on the Dock icon, or passed to `open -a`.
            if url.isFileURL { queue.add([url]) }
        }
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: MediaFormat.openableContentTypes + [.folder],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { queue.add(urls) }
        }
        .alert("Metadata Wash", isPresented: Binding(get: { queue.alertMessage != nil }, set: { if !$0 { queue.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(queue.alertMessage ?? "")
        }
        .frame(minWidth: 820, minHeight: 520)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { isImporting = true } label: { Label("Add Files", systemImage: "plus") }
                .help("Add images or videos")
                .keyboardShortcut("o")
        }
        ToolbarItem(placement: .primaryAction) {
            OutputFolderMenu()
        }
        ToolbarItem(placement: .primaryAction) {
            if queue.isCleaning {
                Button(role: .cancel) { queue.cancel() } label: { Label("Stop", systemImage: "stop.fill") }
                    .help("Stop cleaning")
            } else {
                Button { queue.cleanAll() } label: {
                    Label("Clean \(queue.cleanableItems.count == 0 ? "" : "\(queue.cleanableItems.count) ")File\(queue.cleanableItems.count == 1 ? "" : "s")",
                          systemImage: "sparkles")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .disabled(queue.cleanableItems.isEmpty)
                .help("Create cleaned copies of all inspected files")
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }
}

/// Shows and changes where cleaned copies are saved.
struct OutputFolderMenu: View {
    @Environment(CleaningQueue.self) private var queue

    var body: some View {
        Menu {
            Section("Save cleaned copies to") {
                Text(queue.outputFolderDisplayPath)
            }
            Button("Choose Folder…") { queue.chooseOutputFolder() }
            Button("Use Downloads/Metadata Wash") { queue.resetOutputFolder() }
            Divider()
            Button("Show Output Folder in Finder") { queue.revealOutputFolder() }
        } label: {
            Label(queue.outputFolder.lastPathComponent, systemImage: "folder")
        }
        .accessibilityLabel("Output folder")
        .accessibilityValue(queue.outputFolderDisplayPath)
        .help("Cleaned copies are saved to \(queue.outputFolderDisplayPath). Originals are never modified.")
    }
}

/// Empty state.
struct DropZoneView: View {
    var isTargeted: Bool
    var choose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.badge.checkmark")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, value: isTargeted)
            VStack(spacing: 6) {
                Text("Drop images or videos here")
                    .font(.title2.weight(.semibold))
                Text("Metadata Wash finds camera, location, AI-generation and Content Credentials metadata and creates clean copies. Everything happens on this Mac; your originals are never changed.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
            }
            Button("Choose Files…", action: choose)
                .controlSize(.large)
            Text("JPEG · PNG · WebP · TIFF · HEIC · AVIF · GIF · MP4 · MOV · M4V · WebM · MKV")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                .padding(24)
        }
    }
}

#Preview {
    ContentView()
        .environment(CleaningQueue())
}

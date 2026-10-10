//
//  CleaningQueue.swift
//  Metadata Wash
//

import AppKit
import Foundation
import Observation
import QuickLookThumbnailing

/// Drives the batch: adding files, inspecting, cleaning, and exporting.
@Observable
final class CleaningQueue {
    var items: [MediaItem] = []
    var selection: Set<MediaItem.ID> = []
    private(set) var isCleaning = false
    private(set) var outputFolder: URL
    var alertMessage: String?

    let tools = BundledTools.shared
    @ObservationIgnored private let runner = ExternalToolRunner(workingDirectory: Workspace.shared.root)
    @ObservationIgnored private var cleaningTask: Task<Void, Never>?
    @ObservationIgnored private var inspectionTasks: [MediaItem.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private let inspectionLimiter = ConcurrencyLimiter(limit: 3)

    private static let bookmarkKey = "OutputFolderBookmark"
    private static let maxConcurrentCleanings = 2

    init() {
        Workspace.shared.purge()
        outputFolder = Self.restoreOutputFolder() ?? Self.defaultOutputFolder
    }

    static var defaultOutputFolder: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return downloads.appending(path: "Metadata Wash", directoryHint: .isDirectory)
    }

    var selectedItems: [MediaItem] { items.filter { selection.contains($0.id) } }
    var cleanableItems: [MediaItem] { items.filter { $0.canClean && $0.result == nil } }

    var engineWarnings: [String] {
        var warnings: [String] = []
        if !tools.hasExifTool { warnings.append("ExifTool is missing from this build; inspection and some formats are limited.") }
        if !tools.hasFFmpeg { warnings.append("FFmpeg is missing from this build; videos use a limited fallback.") }
        return warnings
    }

    // MARK: Adding files

    func add(_ urls: [URL]) {
        var newItems: [MediaItem] = []
        let existing = Set(items.map { $0.sourceURL.standardizedFileURL })
        for url in expand(urls) where !existing.contains(url.standardizedFileURL) {
            let item = MediaItem(sourceURL: url)
            newItems.append(item)
        }
        items.append(contentsOf: newItems)
        if selection.isEmpty, let first = newItems.first { selection = [first.id] }
        for item in newItems { startInspection(of: item) }
    }

    /// Expands dropped folders (one level of recursion into subfolders) to their media files.
    private func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let child = enumerator?.nextObject() as? URL {
                    let ext = child.pathExtension.lowercased()
                    if Self.knownExtensions.contains(ext) { result.append(child) }
                }
            } else {
                result.append(url)
            }
        }
        return result
    }

    private static let knownExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "webp", "tif", "tiff", "heic", "heif", "avif", "gif",
        "mp4", "mov", "m4v", "webm", "mkv",
    ]

    private func startInspection(of item: MediaItem) {
        item.phase = .inspecting
        let runner = runner
        let limiter = inspectionLimiter
        inspectionTasks[item.id] = Task { [weak self] in
            await limiter.withSlot {
                await self?.inspect(item, runner: runner)
            }
        }
    }

    private func inspect(_ item: MediaItem, runner: ExternalToolRunner) async {
        do {
            let source = item.sourceURL
            let format = try MetadataInspector.detectFormat(of: source)
            item.format = format
            let workspace = Workspace.shared
            let job = try workspace.makeJobDirectory()
            item.jobDirectory = job
            let copy = try await Task.detached(priority: .userInitiated) {
                try workspace.importCopy(of: source, format: format, into: job)
            }.value
            item.workingCopy = copy
            loadThumbnail(for: item)

            let inspector = MetadataInspector(tools: tools, runner: runner)
            let accessing = source.startAccessingSecurityScopedResource()
            defer { if accessing { source.stopAccessingSecurityScopedResource() } }
            var report = try await inspector.inspect(copy, format: format, attributesOf: source)
            report.fileSize = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0.map(Int64.init) } ?? report.fileSize
            item.report = report
            item.phase = .ready
        } catch is CancellationError {
            return
        } catch {
            item.phase = .failed(error.localizedDescription)
        }
    }

    private func loadThumbnail(for item: MediaItem) {
        guard let url = item.workingCopy else { return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 96),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let image = representation?.nsImage else { return }
            Task { @MainActor in item.thumbnail = image }
        }
    }

    // MARK: Cleaning

    func cleanAll() { clean(cleanableItems) }

    func cleanSelection() { clean(selectedItems.filter(\.canClean)) }

    func clean(_ batch: [MediaItem]) {
        guard !batch.isEmpty, !isCleaning else { return }
        isCleaning = true
        for item in batch { item.phase = .cleaning; item.result = nil }
        let destination = outputFolder
        let runner = runner
        let tools = tools
        cleaningTask = Task { [weak self] in
            let accessing = destination.startAccessingSecurityScopedResource()
            defer { if accessing { destination.stopAccessingSecurityScopedResource() } }
            let cleaner = MetadataCleaner(tools: tools, runner: runner)
            let limiter = ConcurrencyLimiter(limit: Self.maxConcurrentCleanings)
            await withTaskGroup(of: Void.self) { group in
                for item in batch {
                    guard let input = item.workingCopy, let format = item.format, let before = item.report else { continue }
                    let baseName = item.baseName
                    group.addTask {
                        let result = await limiter.withSlot {
                            await cleaner.clean(input, format: format, before: before, destination: destination, baseName: baseName)
                        }
                        await MainActor.run {
                            item.result = result
                            item.phase = result.status == .cancelled ? .ready : .finished
                            if result.status == .cancelled { item.result = nil }
                        }
                    }
                }
            }
            self?.isCleaning = false
        }
    }

    func cancel() {
        cleaningTask?.cancel()
    }

    // MARK: Managing the list

    func remove(_ ids: Set<MediaItem.ID>) {
        for item in items where ids.contains(item.id) {
            inspectionTasks[item.id]?.cancel()
            inspectionTasks[item.id] = nil
            if let job = item.jobDirectory { Workspace.shared.remove(job) }
        }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    func removeAll() {
        guard !isCleaning else { return }
        remove(Set(items.map(\.id)))
    }

    // MARK: Output folder

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Cleaned copies will be saved in this folder."
        panel.directoryURL = outputFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputFolder = url
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }
    }

    func resetOutputFolder() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        outputFolder = Self.defaultOutputFolder
    }

    private static func restoreOutputFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return url
    }

    /// Path shown in the UI, abbreviated with ~ (sandbox container symlinks are resolved first).
    var outputFolderDisplayPath: String {
        let path = outputFolder.resolvingSymlinksInPath().path
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return path }
        let home = String(cString: dir)
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Finder

    func reveal(_ item: MediaItem) {
        guard let url = item.result?.outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url.resolvingSymlinksInPath()])
    }

    func open(_ item: MediaItem) {
        guard let url = item.result?.outputURL else { return }
        NSWorkspace.shared.open(url)
    }

    func revealOutputFolder() {
        let folder = outputFolder
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder.resolvingSymlinksInPath())
    }

    func revealAllOutputs() {
        let urls = items.compactMap { $0.result?.outputURL?.resolvingSymlinksInPath() }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

/// Limits how many async jobs run at once.
actor ConcurrencyLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func withSlot<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        await acquire()
        defer { release() }
        return await work()
    }

    private func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

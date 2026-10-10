//
//  ExternalToolRunner.swift
//  Metadata Wash
//

import Foundation

/// Runs bundled command-line engines (ExifTool, FFmpeg) as child processes.
///
/// Arguments are passed as an array straight to `posix_spawn` through `Process`;
/// nothing is ever interpreted by a shell. The child gets a minimal environment so
/// user shell configuration (PERL5LIB, PERL5OPT, ExifTool config files…) cannot
/// change its behavior. Cancelling the calling task terminates the child.
nonisolated struct ExternalToolRunner: Sendable {
    nonisolated struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data

        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
        var stderrString: String { String(decoding: stderr, as: UTF8.self) }
        var succeeded: Bool { status == 0 }
    }

    /// Working directory and HOME for the child; the app's private temporary directory.
    var workingDirectory: URL
    var timeout: Duration = .seconds(30 * 60)

    @concurrent
    func run(_ executable: URL, arguments: [String]) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": workingDirectory.path,
            "TMPDIR": workingDirectory.path,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let collector = OutputCollector()
        let finished = DispatchGroup()
        // Drain both pipes on background threads so a chatty child never blocks on a full pipe.
        for (pipe, keyPath) in [(stdoutPipe, \OutputCollector.stdout), (stderrPipe, \OutputCollector.stderr)] {
            finished.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                collector.store(data, in: keyPath)
                finished.leave()
            }
        }

        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                process.terminationHandler = { finishedProcess in
                    finished.notify(queue: .global(qos: .utility)) {
                        let (out, err) = collector.values
                        if collector.timedOut {
                            continuation.resume(throwing: CleaningError.toolFailed(
                                tool: executable.lastPathComponent, status: -1, message: "timed out"))
                        } else if collector.cancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(returning: Output(status: finishedProcess.terminationStatus,
                                                                  stdout: out, stderr: err))
                        }
                    }
                }
                do {
                    try process.run()
                    // The write ends belong to the child now; close ours so readToEnd() sees EOF.
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                } catch {
                    process.terminationHandler = nil
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    continuation.resume(throwing: CleaningError.engineUnavailable(
                        "Could not launch \(executable.lastPathComponent): \(error.localizedDescription)"))
                    return
                }
                let seconds = Double(timeout.components.seconds)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak process] in
                    guard let process, process.isRunning else { return }
                    collector.markTimedOut()
                    process.terminate()
                }
            }
        } onCancel: {
            collector.markCancelled()
            if process.isRunning { process.terminate() }
        }
    }
}

/// Thread-safe accumulator for a child's output streams.
private nonisolated final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    var stdout = Data()
    var stderr = Data()
    private var didTimeOut = false
    private var didCancel = false

    func store(_ data: Data, in keyPath: ReferenceWritableKeyPath<OutputCollector, Data>) {
        lock.withLock { self[keyPath: keyPath] = data }
    }

    func markTimedOut() { lock.withLock { didTimeOut = true } }
    func markCancelled() { lock.withLock { didCancel = true } }
    var cancelled: Bool { lock.withLock { didCancel } }

    var timedOut: Bool { lock.withLock { didTimeOut } }
    var values: (Data, Data) { lock.withLock { (stdout, stderr) } }
}

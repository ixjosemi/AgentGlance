import Darwin
import Foundation

import AgentGlanceCore

/// Watches Codex rollout sessions by polling and by directory events.
/// `start()` must be called on the main thread; all scanning, parsing, and
/// state writes run on `workQueue`, which also confines the mutable state.
final class CodexObservationController {
    private let sessionsDirectory: URL
    private let repository: StateRepository
    private let workQueue: DispatchQueue
    private var timer: Timer?

    // Only touched on workQueue after start().
    private var watcher: CodexSessionsWatcher?
    private var directorySource: DispatchSourceFileSystemObject?
    private var processMap: [String: Int32] = [:]

    init(repository: StateRepository, workQueue: DispatchQueue) {
        self.repository = repository
        self.workQueue = workQueue
        sessionsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    func start() {
        workQueue.async { [weak self] in
            self?.refresh()
            self?.startDirectorySource()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.workQueue.async { self.refresh() }
        }
    }

    private func refresh() {
        dispatchPrecondition(condition: .onQueue(workQueue))
        let detected = (try? SystemProcessScanner().activeProcesses()) ?? []
        var currentMap: [String: Int32] = [:]
        for process in detected where process.tool == .codex {
            if currentMap[process.cwd] == nil {
                currentMap[process.cwd] = process.processID
            }
        }
        if currentMap != processMap {
            processMap = currentMap
            let capturedMap = currentMap
            watcher = CodexSessionsWatcher(
                sessionsDirectoryURL: sessionsDirectory,
                repository: repository,
                minimumModificationDate: Date().addingTimeInterval(-3600),
                processIDResolver: { session in capturedMap[session.cwd] }
            )
        }
        do {
            try watcher?.scan()
        } catch {
            NSLog("AgentGlance Codex watcher failed: %@", String(describing: error))
        }
    }

    private func startDirectorySource() {
        dispatchPrecondition(condition: .onQueue(workQueue))
        guard FileManager.default.fileExists(atPath: sessionsDirectory.path) else { return }
        let descriptor = Darwin.open(sessionsDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename],
            queue: workQueue
        )
        source.setEventHandler { [weak self] in self?.refresh() }
        source.setCancelHandler { Darwin.close(descriptor) }
        directorySource = source
        source.resume()
    }
}

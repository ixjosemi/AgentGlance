import Darwin
import Foundation

import AgentGlanceCore

@MainActor
final class CodexObservationController {
    private let sessionsDirectory: URL
    private let repository: StateRepository
    private var watcher: CodexSessionsWatcher?
    private var timer: Timer?
    private var directorySource: DispatchSourceFileSystemObject?
    private var processMap: [String: Int32] = [:]

    init(repository: StateRepository) {
        self.repository = repository
        sessionsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(
            timeInterval: 5,
            target: self,
            selector: #selector(refresh),
            userInfo: nil,
            repeats: true
        )
        startDirectorySource()
    }

    @objc private func refresh() {
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
        guard FileManager.default.fileExists(atPath: sessionsDirectory.path) else { return }
        let descriptor = Darwin.open(sessionsDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.refresh() }
        source.setCancelHandler { Darwin.close(descriptor) }
        directorySource = source
        source.resume()
    }
}

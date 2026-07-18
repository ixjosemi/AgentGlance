import Darwin
import Foundation

/// Drives all background observation from a single serial queue: one process
/// scan per tick feeds both the reaper and the Codex sessions watcher, so no
/// consumer ever triggers its own rescan. Ticks are requested by a heartbeat
/// timer, by Codex sessions directory events, or explicitly by callers.
///
/// `start()` and `stop()` must be called on the main thread; every scan and
/// state write runs on the internal serial queue, which also confines the
/// Codex watcher state.
public final class ObservationScheduler {
    private let repository: StateRepository
    private let processScanner: any ProcessScanning
    private let codexSessionsDirectoryURL: URL
    private let heartbeatInterval: TimeInterval
    private let debounceInterval: TimeInterval
    private let workQueue = DispatchQueue(
        label: "com.agentglance.observation",
        qos: .utility
    )
    private var heartbeatTimer: Timer?

    // Only touched on workQueue.
    private var codexWatcher: CodexSessionsWatcher?
    private var codexProcessMap: [String: Int32] = [:]
    private var codexDirectorySource: DispatchSourceFileSystemObject?
    private var exitWatchers: [pid_t: DispatchSourceProcess] = [:]
    private var tickScheduled = false

    public init(
        repository: StateRepository,
        processScanner: any ProcessScanning = SystemProcessScanner(),
        codexSessionsDirectoryURL: URL? = nil,
        heartbeatInterval: TimeInterval = 5,
        debounceInterval: TimeInterval = 0.3
    ) {
        self.repository = repository
        self.processScanner = processScanner
        self.codexSessionsDirectoryURL = codexSessionsDirectoryURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions", isDirectory: true)
        self.heartbeatInterval = heartbeatInterval
        self.debounceInterval = debounceInterval
    }

    public func start() {
        stop()
        requestTick()
        workQueue.async { [weak self] in self?.startCodexDirectorySource() }
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: heartbeatInterval,
            repeats: true
        ) { [weak self] _ in
            self?.requestTick()
        }
    }

    public func stop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        workQueue.async { [weak self] in
            guard let self else { return }
            self.codexDirectorySource?.cancel()
            self.codexDirectorySource = nil
            self.exitWatchers.values.forEach { $0.cancel() }
            self.exitWatchers.removeAll()
        }
    }

    public func requestTick() {
        workQueue.async { [weak self] in self?.scheduleCoalescedTick() }
    }

    /// Coalesces bursts of tick requests (Codex rollout files receive a write
    /// event per token flush) into one scan per debounce window.
    private func scheduleCoalescedTick() {
        dispatchPrecondition(condition: .onQueue(workQueue))
        guard !tickScheduled else { return }
        tickScheduled = true
        workQueue.asyncAfter(deadline: .now() + debounceInterval) { [weak self] in
            guard let self else { return }
            self.tickScheduled = false
            self.tick()
        }
    }

    private func tick() {
        dispatchPrecondition(condition: .onQueue(workQueue))
        let detected: [DetectedAgentProcess]
        do {
            detected = try processScanner.activeProcesses()
        } catch {
            NSLog("AgentGlance process scan failed: %@", String(describing: error))
            return
        }
        do {
            _ = try ReaperService(repository: repository, processScanner: processScanner)
                .reap(detected: detected)
        } catch {
            NSLog("AgentGlance reaper failed: %@", String(describing: error))
        }
        refreshCodexWatcher(detected: detected)
        refreshExitWatchers(detected: detected)
    }

    /// Registers a kernel exit notification (EVFILT_PROC) per tracked agent
    /// so a closed terminal disappears on the next debounce window instead of
    /// waiting for the heartbeat. Costs nothing between events. A process
    /// that dies before registration is caught by the heartbeat backstop.
    private func refreshExitWatchers(detected: [DetectedAgentProcess]) {
        dispatchPrecondition(condition: .onQueue(workQueue))
        let activeProcessIDs = Set(detected.map(\.processID))
        for (processID, watcher) in exitWatchers where !activeProcessIDs.contains(processID) {
            watcher.cancel()
            exitWatchers[processID] = nil
        }
        for processID in activeProcessIDs where exitWatchers[processID] == nil {
            let watcher = DispatchSource.makeProcessSource(
                identifier: processID,
                eventMask: .exit,
                queue: workQueue
            )
            watcher.setEventHandler { [weak self] in self?.scheduleCoalescedTick() }
            watcher.resume()
            exitWatchers[processID] = watcher
        }
    }

    /// Rebuilds the Codex watcher whenever the set of visible Codex processes
    /// changes, then lets it ingest new rollout lines. Mirrors the process
    /// map into the watcher's PID resolver so rollout sessions attach to the
    /// right process.
    private func refreshCodexWatcher(detected: [DetectedAgentProcess]) {
        var currentMap: [String: Int32] = [:]
        for process in detected where process.tool == .codex {
            if currentMap[process.cwd] == nil {
                currentMap[process.cwd] = process.processID
            }
        }
        if currentMap != codexProcessMap || codexWatcher == nil {
            codexProcessMap = currentMap
            let capturedMap = currentMap
            codexWatcher = CodexSessionsWatcher(
                sessionsDirectoryURL: codexSessionsDirectoryURL,
                repository: repository,
                minimumModificationDate: Date().addingTimeInterval(-3600),
                processIDResolver: { session in capturedMap[session.cwd] }
            )
        }
        do {
            try codexWatcher?.scan()
        } catch {
            NSLog("AgentGlance Codex watcher failed: %@", String(describing: error))
        }
    }

    private func startCodexDirectorySource() {
        dispatchPrecondition(condition: .onQueue(workQueue))
        guard FileManager.default.fileExists(atPath: codexSessionsDirectoryURL.path) else {
            return
        }
        let descriptor = Darwin.open(codexSessionsDirectoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename],
            queue: workQueue
        )
        source.setEventHandler { [weak self] in self?.scheduleCoalescedTick() }
        source.setCancelHandler { Darwin.close(descriptor) }
        codexDirectorySource = source
        source.resume()
    }
}

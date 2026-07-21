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
    private let convoyRunsDirectoryURL: URL
    private let heartbeatInterval: TimeInterval
    private let debounceInterval: TimeInterval
    private let reaper: ReaperService
    private let workQueue = DispatchQueue(
        label: "com.agentglance.observation",
        qos: .utility
    )
    private var heartbeatTimer: DispatchSourceTimer?

    // Only touched on workQueue.
    private var codexWatcher: CodexSessionsWatcher?
    private var convoyWatcher: ConvoyRunsWatcher?
    private var codexProcessMap: [String: Int32] = [:]
    private var codexDirectorySource: DispatchSourceFileSystemObject?
    private var convoyRunsDirectorySource: DispatchSourceFileSystemObject?
    private var convoyRunDirectorySources: [URL: DispatchSourceFileSystemObject] = [:]
    private var exitWatchers: [String: DispatchSourceProcess] = [:]
    private var tickScheduled = false
    private var pendingReasons: TickReasons = []
    private var generation = 0

    private struct TickReasons: OptionSet {
        let rawValue: Int
        static let explicit = TickReasons(rawValue: 1 << 0)
        static let heartbeat = TickReasons(rawValue: 1 << 1)
        static let codexMetadata = TickReasons(rawValue: 1 << 2)
        static let convoyMetadata = TickReasons(rawValue: 1 << 3)
        static let processExit = TickReasons(rawValue: 1 << 4)
    }

    public init(
        repository: StateRepository,
        processScanner: any ProcessScanning = SystemProcessScanner(),
        codexSessionsDirectoryURL: URL? = nil,
        convoyRunsDirectoryURL: URL? = nil,
        heartbeatInterval: TimeInterval = 5,
        debounceInterval: TimeInterval = 0.3
    ) {
        self.repository = repository
        self.processScanner = processScanner
        self.codexSessionsDirectoryURL = codexSessionsDirectoryURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions", isDirectory: true)
        self.convoyRunsDirectoryURL = convoyRunsDirectoryURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".convoy/runs", isDirectory: true)
        self.heartbeatInterval = heartbeatInterval
        self.debounceInterval = debounceInterval
        reaper = ReaperService(repository: repository, processScanner: processScanner)
    }

    public func start() {
        stop()
        requestTick()
        workQueue.async { [weak self] in
            guard let self else { return }
            self.startCodexDirectorySource()
            self.startConvoyRunsDirectorySource()
            let timer = DispatchSource.makeTimerSource(queue: self.workQueue)
            timer.schedule(
                deadline: .now() + self.heartbeatInterval,
                repeating: self.heartbeatInterval,
                leeway: .milliseconds(Int(self.heartbeatInterval * 200))
            )
            timer.setEventHandler { [weak self] in self?.scheduleCoalescedTick(reason: .heartbeat) }
            self.heartbeatTimer = timer
            timer.resume()
        }
    }

    public func stop() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.tickScheduled = false
            self.pendingReasons = []
            self.codexDirectorySource?.cancel()
            self.codexDirectorySource = nil
            self.heartbeatTimer?.cancel()
            self.heartbeatTimer = nil
            self.convoyRunsDirectorySource?.cancel()
            self.convoyRunsDirectorySource = nil
            self.convoyRunDirectorySources.values.forEach { $0.cancel() }
            self.convoyRunDirectorySources.removeAll()
            self.exitWatchers.values.forEach { $0.cancel() }
            self.exitWatchers.removeAll()
        }
    }

    public func requestTick() {
        workQueue.async { [weak self] in self?.scheduleCoalescedTick(reason: .explicit) }
    }

    /// Removes stale persisted state before StateStore establishes the UI's
    /// baseline. This basic pass never invokes Ghostty or Apple Events.
    public func performInitialReconciliation() throws {
        _ = try reaper.reap(detected: processScanner.basicActiveProcesses())
    }

    /// Coalesces bursts of tick requests (Codex rollout files receive a write
    /// event per token flush) into one scan per debounce window.
    private func scheduleCoalescedTick(reason: TickReasons) {
        dispatchPrecondition(condition: .onQueue(workQueue))
        pendingReasons.formUnion(reason)
        guard !tickScheduled else { return }
        tickScheduled = true
        let scheduledGeneration = generation
        workQueue.asyncAfter(deadline: .now() + debounceInterval) { [weak self] in
            guard let self, self.generation == scheduledGeneration else { return }
            self.tickScheduled = false
            let reasons = self.pendingReasons
            self.pendingReasons = []
            self.tick(reasons: reasons)
        }
    }

    private func tick(reasons: TickReasons) {
        dispatchPrecondition(condition: .onQueue(workQueue))
        let detected: [DetectedAgentProcess]
        do {
            detected = try processScanner.basicActiveProcesses()
        } catch {
            NSLog("AgentGlance process scan failed: %@", String(describing: error))
            return
        }
        let convoyResult = scanConvoyRuns(
            detected: detected,
            isHeartbeat: reasons.contains(.heartbeat),
            forceRefresh: reasons.contains(.convoyMetadata)
        )
        do {
            _ = try reaper.reap(
                detected: detected,
                preservingSessionIDs: convoyResult?.preservingSessionIDs ?? []
            )
        } catch {
            NSLog("AgentGlance reaper failed: %@", String(describing: error))
        }
        let enriched = processScanner.enrichTerminalContexts(in: detected)
        do {
            try reaper.applyTerminalEnrichment(basic: detected, enriched: enriched)
        } catch {
            NSLog("AgentGlance terminal enrichment failed: %@", String(describing: error))
        }
        refreshCodexWatcher(detected: enriched)
        if let convoyResult {
            do { try convoyWatcher?.suppressOpenCodeSessions(for: convoyResult) }
            catch { NSLog("AgentGlance convoy suppression failed: %@", String(describing: error)) }
            refreshConvoyRunDirectorySources(convoyResult.runDirectoryURLs)
        }
        refreshExitWatchers(detected: detected)
    }

    /// Convoy metadata events are primary; the heartbeat remains a backstop
    /// for missed vnode events and drives final-state grace expiration.
    private func scanConvoyRuns(
        detected: [DetectedAgentProcess],
        isHeartbeat: Bool,
        forceRefresh: Bool
    ) -> ConvoyRunsWatcher.ScanResult? {
        let watcher = convoyWatcher ?? ConvoyRunsWatcher(
            runsDirectoryURL: convoyRunsDirectoryURL,
            repository: repository
        )
        convoyWatcher = watcher
        do {
            return try watcher.observe(
                detected: detected,
                isHeartbeat: isHeartbeat,
                forceRefresh: forceRefresh
            )
        } catch {
            NSLog("AgentGlance convoy watcher failed: %@", String(describing: error))
        }
        return nil
    }

    /// Registers a kernel exit notification (EVFILT_PROC) per tracked agent
    /// so a closed terminal disappears on the next debounce window instead of
    /// waiting for the heartbeat. Costs nothing between events. A process
    /// that dies before registration is caught by the heartbeat backstop.
    private func refreshExitWatchers(detected: [DetectedAgentProcess]) {
        dispatchPrecondition(condition: .onQueue(workQueue))
        let processesByKey = Dictionary(uniqueKeysWithValues: detected.map {
            (processGenerationKey($0), $0)
        })
        for (key, watcher) in exitWatchers where processesByKey[key] == nil {
            watcher.cancel()
            exitWatchers[key] = nil
        }
        for (key, process) in processesByKey where exitWatchers[key] == nil {
            let watcher = DispatchSource.makeProcessSource(
                identifier: process.processID,
                eventMask: .exit,
                queue: workQueue
            )
            watcher.setEventHandler { [weak self] in self?.scheduleCoalescedTick(reason: .processExit) }
            watcher.resume()
            exitWatchers[key] = watcher
        }
    }

    private func processGenerationKey(_ process: DetectedAgentProcess) -> String {
        if let identity = process.processIdentity {
            return "\(identity.processID)-\(identity.kernelStartTimeMicroseconds)"
        }
        return String(process.processID)
    }

    /// Keeps one long-lived Codex watcher and retargets its PID resolver
    /// whenever the set of visible Codex processes changes, then lets it
    /// ingest new rollout lines. Retargeting in place preserves the read
    /// offsets, so a process-table change never re-ingests already-consumed
    /// rollout bytes.
    private func refreshCodexWatcher(detected: [DetectedAgentProcess]) {
        var currentMap: [String: Int32] = [:]
        for process in detected where process.tool == .codex {
            if currentMap[process.cwd] == nil {
                currentMap[process.cwd] = process.processID
            }
        }
        let capturedMap = currentMap
        let resolver: @Sendable (AgentSession) -> Int32? = { capturedMap[$0.cwd] }
        if let codexWatcher {
            if currentMap != codexProcessMap {
                codexWatcher.processIDResolver = resolver
            }
        } else {
            codexWatcher = CodexSessionsWatcher(
                sessionsDirectoryURL: codexSessionsDirectoryURL,
                repository: repository,
                ingestionWindow: 3600,
                processIDResolver: resolver
            )
        }
        codexProcessMap = currentMap
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
        source.setEventHandler { [weak self] in self?.scheduleCoalescedTick(reason: .codexMetadata) }
        source.setCancelHandler { Darwin.close(descriptor) }
        codexDirectorySource = source
        source.resume()
    }

    private func startConvoyRunsDirectorySource() {
        dispatchPrecondition(condition: .onQueue(workQueue))
        guard convoyRunsDirectorySource == nil,
              FileManager.default.fileExists(atPath: convoyRunsDirectoryURL.path) else { return }
        let descriptor = Darwin.open(convoyRunsDirectoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: workQueue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if !source.data.intersection([.rename, .delete]).isEmpty {
                source.cancel()
                self.convoyRunsDirectorySource = nil
            }
            self.scheduleCoalescedTick(reason: .convoyMetadata)
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        convoyRunsDirectorySource = source
        source.resume()
    }

    private func refreshConvoyRunDirectorySources(_ directoryURLs: Set<URL>) {
        for (url, source) in convoyRunDirectorySources where !directoryURLs.contains(url) {
            source.cancel()
            convoyRunDirectorySources[url] = nil
        }
        for url in directoryURLs where convoyRunDirectorySources[url] == nil {
            let descriptor = Darwin.open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .rename, .delete],
                queue: workQueue
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if !source.data.intersection([.rename, .delete]).isEmpty {
                    source.cancel()
                    self.convoyRunDirectorySources[url] = nil
                }
                self.scheduleCoalescedTick(reason: .convoyMetadata)
            }
            source.setCancelHandler { Darwin.close(descriptor) }
            convoyRunDirectorySources[url] = source
            source.resume()
        }
        if convoyRunsDirectorySource == nil { startConvoyRunsDirectorySource() }
    }
}

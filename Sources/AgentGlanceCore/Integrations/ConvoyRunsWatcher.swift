import Darwin
import Foundation

/// Publishes convoy pipeline runs as sessions by reading the run metadata
/// convoy itself maintains (`~/.convoy/runs/<runID>/metadata.json`). The
/// integration is read-only: convoy needs no hook or plugin, and a run's
/// document dies with its process through the regular reaper pass.
public final class ConvoyRunsWatcher {
    private static let maximumMetadataSize: off_t = 1_048_576
    /// Tolerance between a process's kernel start time and the server
    /// timestamp convoy records, guarding pid reuse across old runs.
    private static let processStartSlack: TimeInterval = 120

    private let runsDirectoryURL: URL
    private let repository: StateRepository
    /// Parse results keyed by metadata file, invalidated by modification
    /// time: only the active run's metadata changes between scans, so
    /// historical runs are parsed at most once per process lifetime.
    private var parsedRunsByFileURL: [URL: (modifiedAt: Date, run: ConvoyRun?)] = [:]
    private var trackedRuns: [String: TrackedRun] = [:]

    public struct ScanResult {
        public let preservingSessionIDs: Set<String>
        public let runDirectoryURLs: Set<URL>
        fileprivate let runs: [ConvoyRun]
    }

    private struct TrackedRun {
        let metadataURL: URL
        let process: DetectedAgentProcess
        let startedAt: Date
        var missedHeartbeats: Int
    }

    public init(runsDirectoryURL: URL, repository: StateRepository) {
        self.runsDirectoryURL = runsDirectoryURL
        self.repository = repository
    }

    public func scan(detected: [DetectedAgentProcess]) throws {
        let result = try observe(detected: detected, isHeartbeat: false)
        try suppressPipelineOwnedOpenCodeSessions(of: result.runs)
    }

    /// Publishes metadata before the reaper runs and retains only associations
    /// that were verified while their server was alive. A process-exit event
    /// can therefore consume serverless final metadata, and one full heartbeat
    /// leaves the terminal state visible long enough for StateStore to notify.
    public func observe(
        detected: [DetectedAgentProcess],
        isHeartbeat: Bool,
        forceRefresh: Bool = false
    ) throws -> ScanResult {
        if forceRefresh { parsedRunsByFileURL.removeAll() }
        let convoyProcesses = detected.filter { $0.tool == .convoy }
        let runs = convoyProcesses.isEmpty
            ? []
            : currentRuns(startedAfter: oldestProcessStart(of: convoyProcesses))
        var liveRuns: [ConvoyRun] = []
        var publishedRunIDs: Set<String> = []
        for process in convoyProcesses {
            guard let run = run(ownedBy: process, in: runs) else { continue }
            let startedAt = run.serverStartedAt ?? Date(timeIntervalSinceNow: -process.elapsedSeconds)
            try repository.save(session(for: run, process: process, startedAt: startedAt))
            trackedRuns[run.runID] = TrackedRun(
                metadataURL: runsDirectoryURL
                    .appendingPathComponent(run.runID, isDirectory: true)
                    .appendingPathComponent("metadata.json"),
                process: process,
                startedAt: startedAt,
                missedHeartbeats: 0
            )
            liveRuns.append(run)
            publishedRunIDs.insert(run.runID)
        }
        for runID in trackedRuns.keys.sorted() where !publishedRunIDs.contains(runID) {
            guard var tracked = trackedRuns[runID] else { continue }
            let processIsPresent = convoyProcesses.contains { processMatches($0, tracked.process) }
            if processIsPresent {
                tracked.missedHeartbeats = 0
            } else if isHeartbeat {
                tracked.missedHeartbeats += 1
            }
            guard tracked.missedHeartbeats <= 1 else {
                trackedRuns[runID] = nil
                continue
            }
            trackedRuns[runID] = tracked
            if forceRefresh { parsedRunsByFileURL[tracked.metadataURL] = nil }
            if let run = parsedRunAtCurrentModificationDate(tracked.metadataURL) {
                try repository.save(session(
                    for: run,
                    process: tracked.process,
                    startedAt: tracked.startedAt
                ))
                liveRuns.append(run)
            }
        }
        return ScanResult(
            preservingSessionIDs: Set(trackedRuns.keys.map { "convoy-\($0)" }),
            runDirectoryURLs: Set(trackedRuns.values.map { $0.metadataURL.deletingLastPathComponent() }),
            runs: liveRuns
        )
    }

    public func suppressOpenCodeSessions(for result: ScanResult) throws {
        try suppressPipelineOwnedOpenCodeSessions(of: result.runs)
    }

    /// Convoy phases run as OpenCode sessions on convoy's embedded server;
    /// when that server loads the AgentGlance plugin, each phase would also
    /// surface as a standalone OpenCode row next to the pipeline it belongs
    /// to. The run metadata names those sessions, so they are removed here —
    /// and again on every scan, which drains any rewrite by the plugin.
    ///
    /// The embedded server shares its cwd with the pipeline's target
    /// directory but is never named by any phase's session ID — Ghostty's
    /// scripting bridge often cannot enumerate its tab, so before its own
    /// plugin ever writes a document, the reaper can create a generic
    /// "reaper-<pid>" fallback for it that sessionID matching would never
    /// catch. Matching by directory as well as by session ID suppresses
    /// that fallback too.
    private func suppressPipelineOwnedOpenCodeSessions(of runs: [ConvoyRun]) throws {
        let pipelineSessionIDs = Set(runs.flatMap { $0.phases.compactMap(\.sessionID) })
        let pipelineTargetDirs = Set(runs.map(\.targetDir))
        guard !pipelineSessionIDs.isEmpty || !pipelineTargetDirs.isEmpty else { return }
        for session in try repository.loadSessions()
        where session.tool == .opencode
            && (pipelineSessionIDs.contains(session.sessionID)
                || (session.source == .reaper && pipelineTargetDirs.contains(session.cwd))) {
            try repository.remove(session)
        }
    }

    // MARK: Run discovery

    private func oldestProcessStart(of processes: [DetectedAgentProcess]) -> Date {
        let longestElapsed = processes.map(\.elapsedSeconds).max() ?? 0
        guard longestElapsed.isFinite else { return .distantPast }
        return Date(timeIntervalSinceNow: -longestElapsed - Self.processStartSlack)
    }

    /// A live process created its run after it started, so metadata last
    /// written before any visible convoy process began cannot describe a
    /// current run and is skipped without parsing.
    private func currentRuns(startedAfter cutoff: Date) -> [ConvoyRun] {
        let runDirectoryURLs = (try? FileManager.default.contentsOfDirectory(
            at: runsDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        var currentMetadataURLs: Set<URL> = []
        var runs: [ConvoyRun] = []
        for runDirectoryURL in runDirectoryURLs {
            let metadataURL = runDirectoryURL.appendingPathComponent("metadata.json")
            guard let modifiedAt = try? metadataURL
                .resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate,
                modifiedAt >= cutoff else {
                continue
            }
            currentMetadataURLs.insert(metadataURL)
            if let run = parsedRun(at: metadataURL, modifiedAt: modifiedAt) {
                runs.append(run)
            }
        }
        // Runs aging out of the cutoff never come back; their cached parses
        // would otherwise accumulate for the lifetime of the app.
        parsedRunsByFileURL = parsedRunsByFileURL.filter {
            currentMetadataURLs.contains($0.key)
        }
        return runs
    }

    private func parsedRun(at metadataURL: URL, modifiedAt: Date) -> ConvoyRun? {
        if let cached = parsedRunsByFileURL[metadataURL], cached.modifiedAt == modifiedAt {
            return cached.run
        }
        let run = secureMetadata(at: metadataURL).flatMap(ConvoyRun.decode)
        parsedRunsByFileURL[metadataURL] = (modifiedAt, run)
        return run
    }

    private func secureMetadata(at url: URL) -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_size >= 0,
              metadata.st_size <= Self.maximumMetadataSize else { return nil }
        return try? handle.readToEnd()
    }

    private func parsedRunAtCurrentModificationDate(_ metadataURL: URL) -> ConvoyRun? {
        guard let modifiedAt = try? metadataURL
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate else { return nil }
        return parsedRun(at: metadataURL, modifiedAt: modifiedAt)
    }

    /// The run a process owns records that process as its server; convoy's
    /// own run browser applies the same check. The recorded server start
    /// must fall within the process's lifetime so a recycled pid can never
    /// resurrect an old run.
    private func run(
        ownedBy process: DetectedAgentProcess,
        in runs: [ConvoyRun]
    ) -> ConvoyRun? {
        let processStartedAt = process.elapsedSeconds.isFinite
            ? Date(timeIntervalSinceNow: -process.elapsedSeconds - Self.processStartSlack)
            : Date.distantPast
        return runs
            .filter {
                $0.serverPid == process.processID
                    && ($0.serverStartedAt ?? .distantPast) >= processStartedAt
            }
            .max { ($0.serverStartedAt ?? .distantPast) < ($1.serverStartedAt ?? .distantPast) }
    }

    // MARK: Session mapping

    private func session(
        for run: ConvoyRun,
        process: DetectedAgentProcess,
        startedAt: Date
    ) -> AgentSession {
        let state = run.sessionState()
        return AgentSession(
            tool: .convoy,
            sessionID: run.runID,
            pid: process.processID,
            processIdentity: process.processIdentity,
            status: state.status,
            attentionReason: state.attentionReason,
            cwd: run.targetDir,
            startedAt: startedAt,
            updatedAt: run.updatedAt,
            terminal: TerminalContext(
                termProgram: process.terminal.termProgram,
                ghosttyTerminalID: process.terminal.ghosttyTerminalID,
                itermSessionID: process.terminal.itermSessionID,
                tmuxPane: process.terminal.tmuxPane,
                tty: process.terminal.tty,
                windowTitleHint: nil
            ),
            currentStep: state.currentStep
        )
    }


    private func processMatches(_ lhs: DetectedAgentProcess, _ rhs: DetectedAgentProcess) -> Bool {
        guard lhs.processID == rhs.processID else { return false }
        guard let left = lhs.processIdentity, let right = rhs.processIdentity else { return true }
        return left == right
    }
}

/// The slice of convoy's run metadata this integration consumes.
struct ConvoyRun {
    struct Phase {
        let name: String
        let status: String
        let startedAt: Date?
        let sessionID: String?
    }

    let runID: String
    let targetDir: String
    let updatedAt: Date
    let serverPid: Int32?
    let serverStartedAt: Date?
    /// Ordered by phase start so the earliest-started phase leads displays.
    let phases: [Phase]
    let humanStepNames: Set<String>

    func sessionState() -> (
        status: SessionStatus,
        attentionReason: AttentionReason?,
        currentStep: String?
    ) {
        let runningPhases = phases.filter { $0.status == "running" || $0.status == "thinking" }
        // A human gate registers as a running phase, but the pipeline is
        // paused waiting for the user's verdict — that is attention, not
        // work, and it outranks agent phases still running alongside it.
        if let waitingGate = runningPhases.first(where: { humanStepNames.contains($0.name) }) {
            return (.needsAttention, .permission, waitingGate.name)
        }
        if !runningPhases.isEmpty {
            let stepNames = runningPhases.map(\.name).joined(separator: " + ")
            return (.working, nil, stepNames)
        }
        if let failedPhase = phases.last(where: { $0.status == "failed" }) {
            return (.needsAttention, .turnComplete, "\(failedPhase.name) failed")
        }
        // Every phase completed or skipped: the run sits on its finish
        // screen waiting to be dismissed, like an agent idling at a prompt.
        return (.idle, nil, nil)
    }

    static func decode(_ data: Data) -> ConvoyRun? {
        guard let file = try? JSONDecoder().decode(MetadataFile.self, from: data) else {
            return nil
        }
        let phases = file.phases
            .map { name, phase in
                Phase(
                    name: name,
                    status: phase.status,
                    startedAt: phase.startedAt.map(date(fromEpochMilliseconds:)),
                    sessionID: phase.sessionID
                )
            }
            .sorted {
                ($0.startedAt ?? .distantFuture, $0.name)
                    < ($1.startedAt ?? .distantFuture, $1.name)
            }
        let humanStepNames = (file.pipeline?.steps ?? [])
            .filter { $0.type == "human" }
            .map(\.name)
        return ConvoyRun(
            runID: file.runID,
            targetDir: file.targetDir,
            updatedAt: date(fromEpochMilliseconds: file.updatedAt),
            serverPid: file.server?.pid,
            serverStartedAt: file.server.map { date(fromEpochMilliseconds: $0.startedAt) },
            phases: phases,
            humanStepNames: Set(humanStepNames)
        )
    }

    private static func date(fromEpochMilliseconds milliseconds: Double) -> Date {
        Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private struct MetadataFile: Decodable {
        struct Server: Decodable {
            let pid: Int32
            let startedAt: Double
        }

        struct PhaseEntry: Decodable {
            let status: String
            let startedAt: Double?
            let sessionID: String?
        }

        struct PipelineStep: Decodable {
            let type: String?
            let name: String
        }

        struct Pipeline: Decodable {
            let steps: [PipelineStep]
        }

        let runID: String
        let targetDir: String
        let updatedAt: Double
        let server: Server?
        let phases: [String: PhaseEntry]
        let pipeline: Pipeline?
    }
}

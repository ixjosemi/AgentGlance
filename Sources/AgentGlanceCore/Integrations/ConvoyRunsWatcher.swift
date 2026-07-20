import Foundation

/// Publishes convoy pipeline runs as sessions by reading the run metadata
/// convoy itself maintains (`~/.convoy/runs/<runID>/metadata.json`). The
/// integration is read-only: convoy needs no hook or plugin, and a run's
/// document dies with its process through the regular reaper pass.
public final class ConvoyRunsWatcher {
    /// Tolerance between a process's kernel start time and the server
    /// timestamp convoy records, guarding pid reuse across old runs.
    private static let processStartSlack: TimeInterval = 120

    private let runsDirectoryURL: URL
    private let repository: StateRepository
    /// Parse results keyed by metadata file, invalidated by modification
    /// time: only the active run's metadata changes between scans, so
    /// historical runs are parsed at most once per process lifetime.
    private var parsedRunsByFileURL: [URL: (modifiedAt: Date, run: ConvoyRun?)] = [:]

    public init(runsDirectoryURL: URL, repository: StateRepository) {
        self.runsDirectoryURL = runsDirectoryURL
        self.repository = repository
    }

    public func scan(detected: [DetectedAgentProcess]) throws {
        let convoyProcesses = detected.filter { $0.tool == .convoy }
        guard !convoyProcesses.isEmpty else { return }
        let runs = currentRuns(startedAfter: oldestProcessStart(of: convoyProcesses))
        var liveRuns: [ConvoyRun] = []
        for process in convoyProcesses {
            guard let run = run(ownedBy: process, in: runs) else { continue }
            try repository.save(session(for: run, process: process))
            liveRuns.append(run)
        }
        try suppressPipelineOwnedOpenCodeSessions(of: liveRuns)
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
            && (pipelineSessionIDs.contains(session.sessionID) || pipelineTargetDirs.contains(session.cwd)) {
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
        let run = (try? Data(contentsOf: metadataURL)).flatMap(ConvoyRun.decode)
        parsedRunsByFileURL[metadataURL] = (modifiedAt, run)
        return run
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
            .filter { $0.serverPid == process.processID && $0.serverStartedAt >= processStartedAt }
            .max { $0.serverStartedAt < $1.serverStartedAt }
    }

    // MARK: Session mapping

    private func session(
        for run: ConvoyRun,
        process: DetectedAgentProcess
    ) -> AgentSession {
        let state = run.sessionState()
        return AgentSession(
            tool: .convoy,
            sessionID: run.runID,
            pid: process.processID,
            status: state.status,
            attentionReason: state.attentionReason,
            cwd: run.targetDir,
            startedAt: run.serverStartedAt,
            updatedAt: run.updatedAt,
            terminal: process.terminal,
            currentStep: state.currentStep
        )
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
    let serverPid: Int32
    let serverStartedAt: Date
    /// Ordered by phase start so the earliest-started phase leads displays.
    let phases: [Phase]
    let humanStepNames: Set<String>

    func sessionState() -> (
        status: SessionStatus,
        attentionReason: AttentionReason?,
        currentStep: String?
    ) {
        let runningPhases = phases.filter { $0.status == "running" }
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
        guard let file = try? JSONDecoder().decode(MetadataFile.self, from: data),
              let server = file.server else {
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
            serverPid: server.pid,
            serverStartedAt: date(fromEpochMilliseconds: server.startedAt),
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

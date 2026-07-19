import Darwin
import Foundation

public struct ReaperResult: Equatable, Sendable {
    public let removedSessionIDs: [String]
    public let createdSessionIDs: [String]
}

public struct ReaperService: Sendable {
    private let repository: StateRepository
    private let processScanner: any ProcessScanning

    public init(
        repository: StateRepository,
        processScanner: any ProcessScanning = SystemProcessScanner()
    ) {
        self.repository = repository
        self.processScanner = processScanner
    }

    public func reap() throws -> ReaperResult {
        try reap(detected: try processScanner.activeProcesses())
    }

    /// Reaps against an already-completed scan, so callers that drive several
    /// consumers from one scan (for example the observation scheduler) do not
    /// trigger a rescan per consumer.
    public func reap(detected activeProcesses: [DetectedAgentProcess]) throws -> ReaperResult {
        let sessions = try repository.loadSessions()
        let activeProcessKeys = Set(activeProcesses.map {
            "\($0.tool.rawValue)-\($0.processID)"
        })
        var removedSessionIDs: [String] = []
        for session in sessions where shouldRemove(session, activeProcessKeys: activeProcessKeys) {
            try repository.remove(session)
            removedSessionIDs.append(session.sessionID)
        }
        let remaining = try rebindDaemonHostedSessions(
            try repository.loadSessions(),
            to: activeProcesses
        )
        let tracked = remaining.reduce(into: [String: AgentSession]()) { result, session in
            let key = "\(session.tool.rawValue)-\(session.pid)"
            if result[key].map({ $0.updatedAt >= session.updatedAt }) != true {
                result[key] = session
            }
        }
        var createdSessionIDs: [String] = []
        for process in activeProcesses {
            let processKey = "\(process.tool.rawValue)-\(process.processID)"
            if let existing = tracked[processKey] {
                try refreshFallback(existing, from: process)
                continue
            }
            let sessionID = "reaper-\(process.processID)"
            try repository.save(AgentSession(
                tool: process.tool,
                sessionID: sessionID,
                pid: process.processID,
                status: .working,
                cwd: process.cwd,
                startedAt: Date(),
                updatedAt: Date(),
                terminal: process.terminal,
                source: .reaper
            ))
            createdSessionIDs.append(sessionID)
        }
        return ReaperResult(
            removedSessionIDs: removedSessionIDs.sorted(),
            createdSessionIDs: createdSessionIDs.sorted()
        )
    }

    private func shouldRemove(
        _ session: AgentSession,
        activeProcessKeys: Set<String>
    ) -> Bool {
        if session.status == .ended || !isAlive(session.pid) {
            return true
        }
        let key = "\(session.tool.rawValue)-\(session.pid)"
        return session.source == .reaper && !activeProcessKeys.contains(key)
    }

    /// Sessions written by a plugin hosted in a shared daemon (OpenCode's
    /// `opencode2 serve`) record the daemon PID, which no scan ever
    /// contains. When exactly one visible same-tool process shares the
    /// session's directory, the session adopts that PID, so fallback dedup
    /// and process liveness track the terminal the user actually sees.
    private func rebindDaemonHostedSessions(
        _ sessions: [AgentSession],
        to activeProcesses: [DetectedAgentProcess]
    ) throws -> [AgentSession] {
        let processesByTool = Dictionary(grouping: activeProcesses, by: \.tool)
        return try sessions.map { session in
            guard session.source != .reaper,
                  let sameToolProcesses = processesByTool[session.tool],
                  !sameToolProcesses.contains(where: { $0.processID == session.pid }) else {
                return session
            }
            let candidates = sameToolProcesses.filter { $0.cwd == session.cwd }
            guard candidates.count == 1 else { return session }
            let rebound = session.replacingProcessID(candidates[0].processID)
            try repository.save(rebound)
            return rebound
        }
    }

    private func refreshFallback(
        _ session: AgentSession,
        from process: DetectedAgentProcess
    ) throws {
        guard session.source == .reaper,
              session.terminal != process.terminal || session.cwd != process.cwd else {
            return
        }
        try repository.save(AgentSession(
            tool: session.tool,
            sessionID: session.sessionID,
            pid: session.pid,
            status: session.status,
            attentionReason: session.attentionReason,
            cwd: process.cwd,
            startedAt: session.startedAt,
            updatedAt: Date(),
            terminal: process.terminal,
            source: .reaper
        ))
    }

    private func isAlive(_ processID: Int32) -> Bool {
        guard processID > 0 else { return false }
        if Darwin.kill(processID, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}

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
        var survivors: [AgentSession] = []
        for session in sessions {
            if shouldRemove(session, activeProcessKeys: activeProcessKeys) {
                try repository.remove(session)
                removedSessionIDs.append(session.sessionID)
            } else {
                survivors.append(session)
            }
        }
        let remaining = try rebindDaemonHostedSessions(survivors, to: activeProcesses)
        let tracked = try pruneSupersededSessions(
            remaining,
            removedSessionIDs: &removedSessionIDs
        )
        var createdSessionIDs: [String] = []
        for process in activeProcesses {
            let processKey = "\(process.tool.rawValue)-\(process.processID)"
            if let existing = tracked[processKey] {
                try refreshFallback(existing, from: process)
                try adoptScannedTerminal(existing, from: process)
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

    /// A terminal shows one session at a time, so several documents pointing
    /// at the same process describe at most one visible session. OpenCode
    /// accumulates the rest — child sessions spawned for subagents and chats
    /// abandoned inside a long-lived TUI — all rebound to the same visible
    /// process. Keep the winner per process, delete the noise.
    private func pruneSupersededSessions(
        _ sessions: [AgentSession],
        removedSessionIDs: inout [String]
    ) throws -> [String: AgentSession] {
        var tracked: [String: AgentSession] = [:]
        for session in sessions {
            let key = "\(session.tool.rawValue)-\(session.pid)"
            guard let incumbent = tracked[key] else {
                tracked[key] = session
                continue
            }
            let loser: AgentSession
            if supersedes(session, incumbent) {
                tracked[key] = session
                loser = incumbent
            } else {
                loser = session
            }
            try repository.remove(loser)
            removedSessionIDs.append(loser.sessionID)
        }
        return tracked
    }

    /// Native documents always beat reaper fallbacks — a fallback carries no
    /// real status, only "the process exists". Among peers, freshest wins;
    /// the session identifier breaks exact timestamp ties deterministically.
    private func supersedes(_ candidate: AgentSession, _ incumbent: AgentSession) -> Bool {
        if (candidate.source == .reaper) != (incumbent.source == .reaper) {
            return incumbent.source == .reaper
        }
        if candidate.updatedAt != incumbent.updatedAt {
            return candidate.updatedAt > incumbent.updatedAt
        }
        return candidate.sessionID > incumbent.sessionID
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

    /// Hook- and plugin-written documents cannot see which Ghostty surface
    /// hosts their process (hooks capture env, which carries no surface ID;
    /// plugins run in daemons), so focusing them falls back to title
    /// heuristics that break as soon as agents rewrite tab titles. The
    /// process scan resolves the exact surface per process — the document
    /// adopts its identifier, keeping its own tty/tmux context and its
    /// updatedAt: enrichment is not activity.
    private func adoptScannedTerminal(
        _ session: AgentSession,
        from process: DetectedAgentProcess
    ) throws {
        guard session.source != .reaper,
              let scannedTerminalID = process.terminal.ghosttyTerminalID,
              session.terminal.ghosttyTerminalID != scannedTerminalID else {
            return
        }
        try repository.save(AgentSession(
            tool: session.tool,
            sessionID: session.sessionID,
            pid: session.pid,
            status: session.status,
            attentionReason: session.attentionReason,
            cwd: session.cwd,
            startedAt: session.startedAt,
            updatedAt: session.updatedAt,
            terminal: TerminalContext(
                termProgram: process.terminal.termProgram ?? session.terminal.termProgram,
                ghosttyTerminalID: scannedTerminalID,
                itermSessionID: session.terminal.itermSessionID,
                tmuxPane: session.terminal.tmuxPane ?? process.terminal.tmuxPane,
                tty: session.terminal.tty ?? process.terminal.tty,
                windowTitleHint: process.terminal.windowTitleHint
                    ?? session.terminal.windowTitleHint
            ),
            source: session.source,
            currentStep: session.currentStep
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

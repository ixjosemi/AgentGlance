import Darwin
import Foundation

public struct ReaperResult: Equatable, Sendable {
    public let removedSessionIDs: [String]
    public let createdSessionIDs: [String]
}

public struct ReaperService: Sendable {
    /// The observation scheduler runs at this cadence. A native hook document
    /// that has been quiet for at least one full pass is verified against the
    /// detected agent set; two consecutive misses distinguish stale state
    /// from one transient per-process metadata read failure.
    public static let staleSessionInterval: TimeInterval = 5

    private let repository: StateRepository
    private let processScanner: any ProcessScanning
    private let now: @Sendable () -> Date
    private let nativeMisses = NativeSessionMissTracker()

    public init(
        repository: StateRepository,
        processScanner: any ProcessScanning = SystemProcessScanner(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.processScanner = processScanner
        self.now = now
    }

    public func reap() throws -> ReaperResult {
        try reap(detected: try processScanner.activeProcesses())
    }

    /// Reaps against an already-completed scan, so callers that drive several
    /// consumers from one scan (for example the observation scheduler) do not
    /// trigger a rescan per consumer.
    public func reap(detected activeProcesses: [DetectedAgentProcess]) throws -> ReaperResult {
        let sessions = try repository.loadSessions()
        nativeMisses.retain(sessionIDs: Set(sessions.map(\.id)))
        let activeProcessKeys = Set(activeProcesses.map {
            "\($0.tool.rawValue)-\($0.processID)"
        })
        var removedSessionIDs: [String] = []
        var survivors: [AgentSession] = []
        for session in sessions {
            if shouldRemove(
                session,
                activeProcessKeys: activeProcessKeys,
                activeProcesses: activeProcesses
            ) {
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
            // No plugin/hook has spoken for this process yet — idle (the
            // silent baseline) beats guessing "working" and lighting the
            // spinner for what may just be a session sitting at a prompt.
            let sessionID = "reaper-\(process.processID)"
            try repository.save(AgentSession(
                tool: process.tool,
                sessionID: sessionID,
                pid: process.processID,
                status: .idle,
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
        activeProcessKeys: Set<String>,
        activeProcesses: [DetectedAgentProcess]
    ) -> Bool {
        if session.status == .ended || !isAlive(session.pid) {
            nativeMisses.clear(sessionID: session.id)
            return true
        }
        let key = "\(session.tool.rawValue)-\(session.pid)"
        if session.source == .reaper {
            return !activeProcessKeys.contains(key)
        }
        // A freshly written native document gets one full scheduler interval
        // to be correlated with its terminal. Hooks/plugins can write before
        // the scanner observes the process, so removing it earlier races a
        // legitimate startup.
        guard now().timeIntervalSince(session.updatedAt) >= Self.staleSessionInterval,
              !activeProcessKeys.contains(key) else {
            nativeMisses.clear(sessionID: session.id)
            return false
        }
        // OpenCode plugins can be hosted by a daemon rather than the visible
        // terminal process. Keep the document only when it can be rebound to
        // exactly one live same-tool process in its working directory.
        let rebindCandidates = candidatesForRebinding(session, to: activeProcesses)
        guard rebindCandidates.count != 1 else {
            nativeMisses.clear(sessionID: session.id)
            return false
        }
        // One per-process metadata read can fail while the process table is
        // changing. Require the same old native document to miss two complete
        // scans before treating its still-live PID as unrelated.
        return nativeMisses.recordMiss(sessionID: session.id) >= 2
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
            let candidates = candidatesForRebinding(session, to: sameToolProcesses)
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
    /// adopts its identifier and keeps following the live tab title, while
    /// keeping its own tty/tmux context and its updatedAt: enrichment is
    /// not activity.
    private func adoptScannedTerminal(
        _ session: AgentSession,
        from process: DetectedAgentProcess
    ) throws {
        guard session.source != .reaper,
              let scannedTerminalID = process.terminal.ghosttyTerminalID else {
            return
        }
        let adoptsIdentifier = session.terminal.ghosttyTerminalID != scannedTerminalID
        let adoptsTitle = titleMeaningfullyChanged(
            scanned: process.terminal.windowTitleHint,
            current: session.terminal.windowTitleHint
        )
        guard adoptsIdentifier || adoptsTitle else { return }
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

    /// Agents decorate tab titles with spinners and status emoji that churn
    /// every few seconds; comparing display-cleaned titles keeps that churn
    /// from rewriting the document — and storming the state observers — on
    /// every tick. A scan without a title never clears an existing one.
    private func titleMeaningfullyChanged(scanned: String?, current: String?) -> Bool {
        guard let scanned else { return false }
        return SessionTitleFormatter.rowTitle(tabTitle: scanned, fallback: "")
            != SessionTitleFormatter.rowTitle(tabTitle: current, fallback: "")
    }

    private func isAlive(_ processID: Int32) -> Bool {
        guard processID > 0 else { return false }
        if Darwin.kill(processID, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    /// Prefer a terminal identity over cwd when several agents of the same
    /// kind run in one repository. Cwd remains the fallback for daemon-hosted
    /// plugins that cannot report a tty or terminal surface.
    private func candidatesForRebinding(
        _ session: AgentSession,
        to activeProcesses: [DetectedAgentProcess]
    ) -> [DetectedAgentProcess] {
        let sameDirectory = activeProcesses.filter {
            $0.tool == session.tool && $0.cwd == session.cwd
        }
        let relationships = sameDirectory.map { process in
            (process, terminalRelationship(session.terminal, process.terminal))
        }
        let terminalMatches = relationships.compactMap { process, relationship in
            relationship == .match ? process : nil
        }
        if !terminalMatches.isEmpty { return terminalMatches }
        // A known-but-different tty or terminal surface is positive evidence
        // that cwd alone refers to another session. Fall back to cwd only
        // when neither side exposes a comparable identity.
        if relationships.contains(where: { $0.1 == .conflict }) { return [] }
        return sameDirectory
    }

    private enum TerminalRelationship {
        case match
        case conflict
        case unavailable
    }

    private func terminalRelationship(
        _ lhs: TerminalContext,
        _ rhs: TerminalContext
    ) -> TerminalRelationship {
        let identities: [(String?, String?)] = [
            (lhs.ghosttyTerminalID, rhs.ghosttyTerminalID),
            (lhs.itermSessionID, rhs.itermSessionID),
            (lhs.tmuxPane, rhs.tmuxPane),
            (lhs.tty, rhs.tty),
        ]
        for (left, right) in identities {
            guard let left, let right else { continue }
            return left == right ? .match : .conflict
        }
        return .unavailable
    }
}

private final class NativeSessionMissTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func recordMiss(sessionID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        counts[sessionID, default: 0] += 1
        return counts[sessionID, default: 0]
    }

    func clear(sessionID: String) {
        lock.lock()
        counts[sessionID] = nil
        lock.unlock()
    }

    func retain(sessionIDs: Set<String>) {
        lock.lock()
        counts = counts.filter { sessionIDs.contains($0.key) }
        lock.unlock()
    }
}

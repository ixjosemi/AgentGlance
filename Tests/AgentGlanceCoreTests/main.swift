import Foundation

import AgentGlanceCore

enum TestFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case let .expectation(message): message
        }
    }
}

func expect<T: Equatable>(_ actual: T, equals expected: T, _ message: String) throws {
    guard actual == expected else {
        throw TestFailure.expectation("\(message): expected \(expected), got \(actual)")
    }
}

func testVersionOneStateDocumentReconstructsSession() throws {
    let data = Data(
        """
        {
          "schema_version": 1,
          "tool": "claude",
          "session_id": "session-1",
          "pid": 12345,
          "status": "needs_attention",
          "attention_reason": "permission",
          "cwd": "/Users/example/project",
          "started_at": "2026-07-18T10:00:00Z",
          "updated_at": "2026-07-18T10:05:32Z",
          "terminal": {
            "term_program": "ghostty",
            "iterm_session_id": null,
            "tmux_pane": "%3",
            "tty": "/dev/ttys004",
            "window_title_hint": "project — claude"
          }
        }
        """.utf8
    )

    let session = try AgentSession.decode(from: data)

    try expect(session.tool, equals: .claude, "tool")
    try expect(session.status, equals: .needsAttention, "status")
    try expect(session.attentionReason, equals: .permission, "attention reason")
    try expect(session.terminal.tmuxPane, equals: "%3", "tmux pane")
    try expect(session.projectName, equals: "project", "project name")
}

func testConvoySessionDecodesCurrentStep() throws {
    let data = Data(
        """
        {
          "schema_version": 1,
          "tool": "convoy",
          "session_id": "20260719-101010-abcd",
          "pid": 4242,
          "status": "working",
          "attention_reason": null,
          "cwd": "/tmp/project",
          "started_at": "2026-07-19T10:00:00Z",
          "updated_at": "2026-07-19T10:05:00Z",
          "terminal": {},
          "current_step": "security-audit"
        }
        """.utf8
    )

    let session = try AgentSession.decode(from: data)

    try expect(session.tool, equals: .convoy, "tool")
    try expect(session.currentStep, equals: "security-audit", "current step")

    let withoutStep = try AgentSession.decode(from: validStateJSON(sessionID: "plain", status: "idle"))
    try expect(withoutStep.currentStep, equals: nil, "absent step decodes as nil")
}

func testUnsupportedSchemaVersionIsRejected() throws {
    let data = Data(
        """
        {
          "schema_version": 2,
          "tool": "claude",
          "session_id": "session-1",
          "pid": 12345,
          "status": "working",
          "attention_reason": null,
          "cwd": "/tmp/project",
          "started_at": "2026-07-18T10:00:00Z",
          "updated_at": "2026-07-18T10:00:00Z",
          "terminal": {}
        }
        """.utf8
    )

    do {
        _ = try AgentSession.decode(from: data)
        throw TestFailure.expectation("schema version 2 was accepted")
    } catch let error as AgentSessionError {
        try expect(error, equals: .unsupportedSchemaVersion(2), "schema error")
    }
}

func testStateRepositoryReconstructsSessionsFromDisk() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = validStateJSON(sessionID: "session-1", status: "working")
    let second = validStateJSON(sessionID: "session-2", status: "idle")
    try first.write(to: directory.appendingPathComponent("claude-session-1.json"))
    try second.write(to: directory.appendingPathComponent("claude-session-2.json"))

    let sessions = try StateRepository(directoryURL: directory).loadSessions()

    try expect(Set(sessions.map(\.sessionID)), equals: ["session-1", "session-2"], "session IDs")
}

func testMissingStateDirectoryLoadsAsEmpty() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    let sessions = try StateRepository(directoryURL: directory).loadSessions()

    try expect(sessions.isEmpty, equals: true, "sessions")
}

func testMalformedStateDoesNotHideValidSessions() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try validStateJSON(sessionID: "valid", status: "working")
        .write(to: directory.appendingPathComponent("claude-valid.json"))
    try Data("not-json".utf8)
        .write(to: directory.appendingPathComponent("claude-broken.json"))

    let sessions = try StateRepository(directoryURL: directory).loadSessions()

    try expect(sessions.map(\.sessionID), equals: ["valid"], "valid sessions")
}

func testSavingSessionPublishesCanonicalStateFile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = try AgentSession.decode(
        from: validStateJSON(sessionID: "session/unsafe", status: "working")
    )

    try StateRepository(directoryURL: directory).save(session)

    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    try expect(names, equals: ["claude-c2Vzc2lvbi91bnNhZmU.json"], "state file names")
}

func testStateFilesArePrivateAndSessionNamesDoNotCollide() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let first = try AgentSession.decode(from: validStateJSON(sessionID: "a/b", status: "working"))
    let second = try AgentSession.decode(from: validStateJSON(sessionID: "a_b", status: "working"))

    try repository.save(first)
    try repository.save(second)

    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    try expect(names.count, equals: 2, "collision-resistant state file names")
    let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    let fileMode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(names[0]).path)[.posixPermissions] as? NSNumber
    try expect(directoryMode?.intValue, equals: 0o700, "state directory permissions")
    try expect(fileMode?.intValue, equals: 0o600, "state file permissions")
}

func testStateRepositoryIgnoresSymbolicLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let directory = root.appendingPathComponent("state")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let external = root.appendingPathComponent("external.json")
    try validStateJSON(sessionID: "linked", status: "working").write(to: external)
    try FileManager.default.createSymbolicLink(
        at: directory.appendingPathComponent("claude-linked.json"),
        withDestinationURL: external
    )

    let sessions = try StateRepository(directoryURL: directory).loadSessions()

    try expect(sessions.isEmpty, equals: true, "symbolic-link states")
}

/// A freshly launched Claude sits at the prompt waiting for input, so
/// SessionStart must not paint the session green.
func testClaudeSessionStartCreatesIdleState() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let processor = ClaudeHookProcessor(repository: StateRepository(directoryURL: directory))
    let payload = Data(#"{"session_id":"claude-1","cwd":"/tmp/my-project"}"#.utf8)
    let now = Date(timeIntervalSince1970: 1_752_836_400)

    try processor.process(
        event: "SessionStart",
        payload: payload,
        environment: ["TERM_PROGRAM": "ghostty", "TMUX_PANE": "%7"],
        processID: 4321,
        now: now
    )

    let session = try StateRepository(directoryURL: directory).loadSessions().first
        .unwrap(or: "session was not saved")
    try expect(session.status, equals: .idle, "session status")
    try expect(session.startedAt, equals: now, "started at")
    try expect(session.terminal.termProgram, equals: "ghostty", "terminal program")
    try expect(session.terminal.tmuxPane, equals: "%7", "tmux pane")
}

/// SessionStart also fires after /compact, /clear, and auto-compaction —
/// mid-conversation moments that say nothing about whether Claude is
/// working. An existing session keeps its current status.
func testClaudeSessionStartPreservesExistingStatus() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let processor = ClaudeHookProcessor(repository: repository)
    let payload = Data(#"{"session_id":"claude-1","cwd":"/tmp/project"}"#.utf8)
    try processor.process(
        event: "UserPromptSubmit",
        payload: payload,
        environment: [:],
        processID: 4321,
        now: Date(timeIntervalSince1970: 100)
    )

    try processor.process(
        event: "SessionStart",
        payload: payload,
        environment: [:],
        processID: 4321,
        now: Date(timeIntervalSince1970: 200)
    )

    let session = try repository.loadSessions().first.unwrap(or: "session was not saved")
    try expect(session.status, equals: .working, "status preserved across auto-compact")
    try expect(session.startedAt, equals: Date(timeIntervalSince1970: 100), "original start time")
}

func testClaudePermissionNotificationRequestsAttention() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let processor = ClaudeHookProcessor(repository: StateRepository(directoryURL: directory))
    let start = Data(#"{"session_id":"claude-1","cwd":"/tmp/project"}"#.utf8)
    try processor.process(
        event: "SessionStart",
        payload: start,
        environment: [:],
        processID: 4321,
        now: Date(timeIntervalSince1970: 100)
    )
    let notification = Data(
        #"{"session_id":"claude-1","cwd":"/tmp/project","notification_type":"permission_prompt"}"#.utf8
    )

    try processor.process(
        event: "Notification",
        payload: notification,
        environment: [:],
        processID: 4321,
        now: Date(timeIntervalSince1970: 200)
    )

    let session = try StateRepository(directoryURL: directory).loadSessions().first
        .unwrap(or: "session was not saved")
    try expect(session.status, equals: .needsAttention, "session status")
    try expect(session.attentionReason, equals: .permission, "attention reason")
    try expect(session.startedAt, equals: Date(timeIntervalSince1970: 100), "original start time")
}

func testClaudeLifecycleEventsProduceExpectedStates() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let processor = ClaudeHookProcessor(repository: repository)
    let basePayload = #"{"session_id":"claude-1","cwd":"/tmp/project"}"#
    try processor.process(
        event: "SessionStart",
        payload: Data(basePayload.utf8),
        environment: [:],
        processID: 99
    )
    let transitions: [(event: String, payload: String, status: SessionStatus, reason: AttentionReason?)] = [
        (
            "Notification",
            #"{"session_id":"claude-1","cwd":"/tmp/project","notification_type":"idle_prompt"}"#,
            .needsAttention,
            .idlePrompt
        ),
        ("UserPromptSubmit", basePayload, .working, nil),
        ("Stop", basePayload, .idle, nil),
        ("SessionEnd", basePayload, .ended, nil),
    ]

    for transition in transitions {
        try processor.process(
            event: transition.event,
            payload: Data(transition.payload.utf8),
            environment: [:],
            processID: 99
        )
        let session = try repository.loadSessions().first.unwrap(or: "session was not saved")
        try expect(session.status, equals: transition.status, "\(transition.event) status")
        try expect(session.attentionReason, equals: transition.reason, "\(transition.event) reason")
    }
}

extension Optional {
    func unwrap(or message: String) throws -> Wrapped {
        guard let self else { throw TestFailure.expectation(message) }
        return self
    }
}

func validStateJSON(
    sessionID: String,
    status: String,
    pid: Int32 = 12345,
    tool: String = "claude"
) -> Data {
    Data(
        """
        {
          "schema_version": 1,
          "tool": "\(tool)",
          "session_id": "\(sessionID)",
          "pid": \(pid),
          "status": "\(status)",
          "attention_reason": null,
          "cwd": "/tmp/project",
          "started_at": "2026-07-18T10:00:00Z",
          "updated_at": "2026-07-18T10:00:00Z",
          "terminal": {}
        }
        """.utf8
    )
}

func testReaperDeletesStateForDeadProcess() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    try repository.save(AgentSession.decode(
        from: validStateJSON(sessionID: "ghost", status: "working", pid: 999_999)
    ))

    let result = try ReaperService(repository: repository, processScanner: TestProcessScanner([])).reap()

    try expect(result.removedSessionIDs, equals: ["ghost"], "removed sessions")
    try expect(try repository.loadSessions().isEmpty, equals: true, "remaining sessions")
}

struct TestProcessScanner: ProcessScanning {
    let processes: [DetectedAgentProcess]

    init(_ processes: [DetectedAgentProcess]) {
        self.processes = processes
    }

    func activeProcesses() throws -> [DetectedAgentProcess] { processes }
}

func testReaperCreatesFallbackStateForUntrackedProcess() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let process = DetectedAgentProcess(
        tool: .claude,
        processID: Int32(getpid()),
        cwd: "/tmp/fallback",
        terminal: TerminalContext(tty: "/dev/ttys001")
    )

    _ = try ReaperService(
        repository: repository,
        processScanner: TestProcessScanner([process])
    ).reap()

    let session = try repository.loadSessions().first.unwrap(or: "fallback state was not saved")
    try expect(session.source, equals: .reaper, "session source")
    try expect(session.pid, equals: Int32(getpid()), "session PID")
}

func testReaperReapsAgainstProvidedScan() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    try repository.save(AgentSession.decode(
        from: validStateJSON(sessionID: "ghost", status: "working", pid: 999_999)
    ))
    let liveProcess = DetectedAgentProcess(
        tool: .opencode,
        processID: Int32(getpid()),
        cwd: "/tmp/shared-scan",
        terminal: TerminalContext(tty: "/dev/ttys001")
    )

    // A scheduler scans once per tick and hands the result to the reaper,
    // so reaping must work against a provided scan without rescanning.
    let result = try ReaperService(repository: repository).reap(detected: [liveProcess])

    try expect(result.removedSessionIDs, equals: ["ghost"], "removed sessions")
    try expect(result.createdSessionIDs, equals: ["reaper-\(getpid())"], "created sessions")
    let session = try repository.loadSessions().first.unwrap(or: "fallback state was not saved")
    try expect(session.cwd, equals: "/tmp/shared-scan", "fallback cwd")
}

func testReaperRebindsDaemonHostedSessionToVisibleProcess() throws {
    // The OpenCode plugin runs inside the detached `opencode2 serve` daemon,
    // so its state documents record the daemon PID — alive forever and never
    // present in a scan. Such a session must adopt the PID of the visible
    // same-tool process in its directory: no duplicate fallback appears and
    // the session dies with the terminal instead of outliving it.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let now = Date(timeIntervalSince1970: 100)
    try repository.save(AgentSession(
        tool: .opencode, sessionID: "daemon-doc", pid: 1, status: .idle,
        cwd: "/tmp/oc-project", startedAt: now, updatedAt: now
    ))
    let visibleProcess = DetectedAgentProcess(
        tool: .opencode,
        processID: Int32(getpid()),
        cwd: "/tmp/oc-project",
        terminal: TerminalContext(tty: "/dev/ttys001")
    )

    let result = try ReaperService(repository: repository).reap(detected: [visibleProcess])

    try expect(result.createdSessionIDs, equals: [], "no fallback for an adopted process")
    let session = try repository.loadSessions().first.unwrap(or: "daemon session disappeared")
    try expect(session.sessionID, equals: "daemon-doc", "session identity survives")
    try expect(session.pid, equals: Int32(getpid()), "session adopts the visible PID")
}

func testReaperPrunesSupersededSessionsForSameProcess() throws {
    // A terminal shows one session at a time, so several documents pointing
    // at the same process describe at most one visible session — the most
    // recently updated one. OpenCode accumulates the rest: child sessions
    // spawned for subagents and chats abandoned inside a long-lived TUI.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let pid = Int32(getpid())
    for (sessionID, updatedAt) in [("abandoned-chat", 100.0), ("subagent-child", 200.0), ("current", 300.0)] {
        try repository.save(AgentSession(
            tool: .opencode, sessionID: sessionID, pid: pid, status: .working,
            cwd: "/tmp/oc-project", startedAt: Date(timeIntervalSince1970: 50),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        ))
    }
    let visibleProcess = DetectedAgentProcess(
        tool: .opencode,
        processID: pid,
        cwd: "/tmp/oc-project",
        terminal: TerminalContext(tty: "/dev/ttys001")
    )

    let result = try ReaperService(repository: repository).reap(detected: [visibleProcess])

    try expect(result.removedSessionIDs, equals: ["abandoned-chat", "subagent-child"], "pruned sessions")
    try expect(result.createdSessionIDs, equals: [], "no fallback while a native doc tracks the process")
    let sessions = try repository.loadSessions()
    try expect(sessions.map(\.sessionID), equals: ["current"], "surviving session")
}

func testReaperPrefersNativeSessionOverNewerFallback() throws {
    // The OpenCode plugin writes documents directly (bypassing save()'s
    // fallback supersession), so a reaper fallback can coexist with native
    // documents for the same process. The fallback loses even when its
    // updated_at is newer — it carries no real status.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let pid = Int32(getpid())
    try repository.save(AgentSession(
        tool: .opencode, sessionID: "reaper-\(pid)", pid: pid, status: .working,
        cwd: "/tmp/oc-project", startedAt: Date(timeIntervalSince1970: 400),
        updatedAt: Date(timeIntervalSince1970: 400), source: .reaper
    ))
    // Written directly so save() cannot apply its supersession rules.
    let nativeJSON = validStateJSON(sessionID: "native", status: "idle", pid: pid, tool: "opencode")
    try nativeJSON.write(to: directory.appendingPathComponent(
        "opencode-\(Data("native".utf8).base64EncodedString()).json"
    ))
    let visibleProcess = DetectedAgentProcess(
        tool: .opencode,
        processID: pid,
        cwd: "/tmp/project",
        terminal: TerminalContext(tty: "/dev/ttys001")
    )

    let result = try ReaperService(repository: repository).reap(detected: [visibleProcess])

    try expect(result.removedSessionIDs, equals: ["reaper-\(pid)"], "fallback pruned")
    let sessions = try repository.loadSessions()
    try expect(sessions.map(\.sessionID), equals: ["native"], "native session survives")
}

func testObservationSchedulerTickPersistsFallbackState() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let liveProcess = DetectedAgentProcess(
        tool: .opencode,
        processID: Int32(getpid()),
        cwd: "/tmp/scheduler-project",
        terminal: TerminalContext(tty: nil)
    )
    let scheduler = ObservationScheduler(
        repository: repository,
        processScanner: TestProcessScanner([liveProcess]),
        codexSessionsDirectoryURL: directory.appendingPathComponent("codex", isDirectory: true)
    )

    scheduler.requestTick()

    let deadline = Date().addingTimeInterval(2)
    var sessions: [AgentSession] = []
    repeat {
        sessions = (try? repository.loadSessions()) ?? []
        if sessions.isEmpty { usleep(20_000) }
    } while sessions.isEmpty && Date() < deadline
    try expect(sessions.map(\.sessionID), equals: ["reaper-\(getpid())"], "fallback session")
    try expect(sessions.first?.cwd, equals: "/tmp/scheduler-project", "fallback cwd")
}

func testObservationSchedulerPublishesConvoyRunOnTick() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: "20260719-161616-schd",
        serverPid: Int32(getpid()),
        serverStartedAt: Date().addingTimeInterval(-300),
        phases: [("implementer", "running", "ses_impl")]
    )
    let scheduler = ObservationScheduler(
        repository: repository,
        processScanner: TestProcessScanner([detectedConvoyProcess()]),
        codexSessionsDirectoryURL: stateDirectoryURL.appendingPathComponent("codex", isDirectory: true),
        convoyRunsDirectoryURL: runsDirectoryURL
    )

    scheduler.requestTick()

    let deadline = Date().addingTimeInterval(2)
    var published: AgentSession?
    repeat {
        published = (try? repository.loadSessions())?
            .first { $0.sessionID == "20260719-161616-schd" }
        if published == nil { usleep(20_000) }
    } while published == nil && Date() < deadline
    let session = try published.unwrap(or: "scheduler never published the convoy run")
    try expect(session.tool, equals: .convoy, "tool")
    try expect(session.status, equals: .working, "status")
    try expect(session.currentStep, equals: "implementer", "current step")
}

final class CountingProcessScanner: ProcessScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func activeProcesses() throws -> [DetectedAgentProcess] {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return []
    }

    var scanCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Reports the process only while it is actually alive, mimicking a real
/// scan across a process death.
struct LivenessProcessScanner: ProcessScanning {
    let process: DetectedAgentProcess

    func activeProcesses() throws -> [DetectedAgentProcess] {
        Darwin.kill(process.processID, 0) == 0 ? [process] : []
    }
}

func testObservationSchedulerReapsImmediatelyWhenProcessExits() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["300"]
    try child.run()
    defer { child.terminate() }
    let scheduler = ObservationScheduler(
        repository: repository,
        processScanner: LivenessProcessScanner(process: DetectedAgentProcess(
            tool: .claude,
            processID: child.processIdentifier,
            cwd: "/tmp/exit-watch",
            terminal: TerminalContext(tty: nil)
        )),
        codexSessionsDirectoryURL: directory.appendingPathComponent("codex", isDirectory: true),
        debounceInterval: 0.05
    )

    scheduler.requestTick()
    var deadline = Date().addingTimeInterval(2)
    while (try repository.loadSessions()).isEmpty, Date() < deadline {
        usleep(20_000)
    }
    try expect((try repository.loadSessions()).count, equals: 1, "session tracked while alive")

    // No heartbeat is running and no further ticks are requested: only the
    // kernel exit event can trigger the reap.
    child.terminate()
    deadline = Date().addingTimeInterval(1.5)
    while !(try repository.loadSessions()).isEmpty, Date() < deadline {
        usleep(20_000)
    }
    try expect(
        (try repository.loadSessions()).isEmpty,
        equals: true,
        "session reaped on process exit without a heartbeat"
    )
}

func testObservationSchedulerCoalescesTickBursts() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let scanner = CountingProcessScanner()
    let scheduler = ObservationScheduler(
        repository: StateRepository(directoryURL: directory),
        processScanner: scanner,
        codexSessionsDirectoryURL: directory.appendingPathComponent("codex", isDirectory: true),
        debounceInterval: 0.1
    )

    for _ in 0..<5 {
        scheduler.requestTick()
    }
    usleep(400_000)

    try expect(
        scanner.scanCount,
        equals: 1,
        "a burst of tick requests must coalesce into a single scan"
    )
}

func testNativeStateReplacesReaperFallbackForSameProcess() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    let now = Date(timeIntervalSince1970: 100)
    try repository.save(AgentSession(
        tool: .claude, sessionID: "reaper-10", pid: 10, status: .working,
        cwd: "/tmp/project", startedAt: now, updatedAt: now, source: .reaper
    ))
    try repository.save(AgentSession(
        tool: .claude, sessionID: "native", pid: 10, status: .working,
        cwd: "/tmp/project", startedAt: now, updatedAt: now
    ))

    let sessions = try repository.loadSessions()
    try expect(sessions.map(\.sessionID), equals: ["native"], "sessions")
}

func testSessionDurationFormatterRendersCompactDurations() throws {
    let start = Date(timeIntervalSince1970: 0)
    let cases: [(elapsed: TimeInterval, expected: String)] = [
        (30, "<1m"),
        (59, "<1m"),
        (60, "1m"),
        (47 * 60, "47m"),
        (3_600, "1h"),
        (3_600 + 12 * 60, "1h 12m"),
        (26 * 3_600, "1d 2h"),
        (3 * 86_400, "3d"),
        (-5, "<1m"),
    ]
    for (elapsed, expected) in cases {
        try expect(
            SessionDurationFormatter.string(from: start, to: start.addingTimeInterval(elapsed)),
            equals: expected,
            "duration for \(elapsed)s"
        )
    }
}

func testDebugRendererShowsToolCountsAndSessionState() throws {
    let claude = try AgentSession.decode(from: validStateJSON(sessionID: "c1", status: "working"))
    let output = DebugRenderer.render(sessions: [claude])

    guard output.contains("claude: 1"), output.contains("c1  working  project") else {
        throw TestFailure.expectation("unexpected debug output: \(output)")
    }
}

func testCLIParsesDebugCommand() throws {
    try expect(try CLICommand.parse(arguments: ["debug"]), equals: .debug, "CLI command")
}

func testCLIParsesClaudeHookCommand() throws {
    let command = try CLICommand.parse(
        arguments: ["hook", "claude", "Notification", "--pid", "42"]
    )
    try expect(command, equals: .claudeHook(event: "Notification", processID: 42), "CLI command")
}

func testCLIParsesCodexNotifyCommand() throws {
    let command = try CLICommand.parse(arguments: ["hook", "codex-notify", "--pid", "42"])
    try expect(command, equals: .codexNotify(processID: 42), "CLI command")
}

func testCaptureContextEmitsTerminalJSON() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
        BundledResources.captureContextScriptURL.path,
        "/tmp/my-project",
        "claude",
        "1",
    ]
    process.environment = [
        "PATH": "/usr/bin:/bin",
        "TERM_PROGRAM": "ghostty",
        "TMUX_PANE": "%8",
    ]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    try expect(process.terminationStatus, equals: 0, "capture-context exit status")
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    try expect(json?["term_program"] as? String, equals: "ghostty", "terminal program")
    try expect(json?["tmux_pane"] as? String, equals: "%8", "tmux pane")
    try expect(
        json?["window_title_hint"] as? String,
        equals: "my-project — claude",
        "window title hint"
    )
}

func testClaudeHookWrapperForwardsPayloadAndEvent() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let wrapperURL = directory.appendingPathComponent("claude-hook.sh")
    try FileManager.default.copyItem(at: BundledResources.claudeHookScriptURL, to: wrapperURL)
    let binaryURL = directory.appendingPathComponent("agentglance")
    try Data(
        """
        #!/bin/sh
        /usr/bin/printf '%s|%s|%s|%s|%s' "$#" "$1" "$2" "$3" "$4" > "$CAPTURE_DIR/args"
        /bin/cat > "$CAPTURE_DIR/payload"
        """.utf8
    ).write(to: binaryURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: binaryURL.path
    )
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [wrapperURL.path, "Stop"]
    process.environment = ["PATH": "/usr/bin:/bin", "CAPTURE_DIR": directory.path]
    let input = Pipe()
    process.standardInput = input
    try process.run()
    input.fileHandleForWriting.write(Data(#"{"session_id":"abc"}"#.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()

    try expect(process.terminationStatus, equals: 0, "wrapper exit status")
    let arguments = try String(contentsOf: directory.appendingPathComponent("args"), encoding: .utf8)
    guard arguments.hasPrefix("5|hook|claude|Stop|--pid") else {
        throw TestFailure.expectation("unexpected wrapper arguments: \(arguments)")
    }
    let payload = try String(contentsOf: directory.appendingPathComponent("payload"), encoding: .utf8)
    try expect(payload, equals: #"{"session_id":"abc"}"#, "hook payload")
}

func testStateStoreReloadFiltersEndedSessionsWithoutWriting() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    try repository.save(AgentSession.decode(
        from: validStateJSON(sessionID: "active", status: "working", pid: Int32(getpid()))
    ))
    try repository.save(AgentSession.decode(
        from: validStateJSON(sessionID: "ended", status: "ended", pid: Int32(getpid()))
    ))
    let store = StateStore(repository: repository)

    try store.reload()

    try expect(store.sessions.map(\.sessionID), equals: ["active"], "active sessions")
    // Reloading is a pure read: deleting ended state belongs to the reaper.
    // A reload that writes re-triggers its own directory observation and can
    // storm the main thread (observed 2026-07-18 at ~100% CPU).
    try expect(
        try repository.loadSessions().map(\.sessionID).sorted(),
        equals: ["active", "ended"],
        "state files on disk"
    )
}

func testStateStorePollingObservesNewStateFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = StateStore(repository: StateRepository(directoryURL: directory))
    try store.startObserving(pollInterval: 0.05, layers: .polling)
    defer { store.stopObserving() }
    try validStateJSON(sessionID: "appeared", status: "working", pid: Int32(getpid()))
        .writeAtomically(to: directory.appendingPathComponent("claude-appeared.json"))

    let deadline = Date().addingTimeInterval(1)
    while store.sessions.isEmpty, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    try expect(store.sessions.map(\.sessionID), equals: ["appeared"], "observed sessions")
}

func testStateStoreFileEventsObserveNewStateFilesWithoutPolling() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = StateStore(repository: StateRepository(directoryURL: directory))
    try store.startObserving(pollInterval: nil, layers: .fileSystem)
    defer { store.stopObserving() }
    try validStateJSON(sessionID: "file-event", status: "working", pid: Int32(getpid()))
        .writeAtomically(to: directory.appendingPathComponent("claude-file-event.json"))

    let deadline = Date().addingTimeInterval(1)
    while store.sessions.isEmpty, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    try expect(store.sessions.map(\.sessionID), equals: ["file-event"], "observed sessions")
}

func testStateStoreDarwinNotificationObservesNewStateFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = StateStore(repository: StateRepository(directoryURL: directory))
    try store.startObserving(pollInterval: nil, layers: .darwinNotification)
    defer { store.stopObserving() }
    try validStateJSON(sessionID: "notified", status: "working", pid: Int32(getpid()))
        .writeAtomically(to: directory.appendingPathComponent("claude-notified.json"))
    StateChangeNotifier.post()

    let deadline = Date().addingTimeInterval(1)
    while store.sessions.isEmpty, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    try expect(store.sessions.map(\.sessionID), equals: ["notified"], "observed sessions")
}

func testToolSummaryCountsSessionsAndAttention() throws {
    let sessions = [
        try AgentSession.decode(from: validStateJSON(sessionID: "one", status: "working")),
        try AgentSession.decode(from: validStateJSON(sessionID: "two", status: "needs_attention")),
    ]

    let summary = ToolSummary(tool: .claude, sessions: sessions)

    try expect(summary.sessionCount, equals: 2, "session count")
    try expect(summary.needsAttention, equals: true, "attention state")
    try expect(
        ToolSummary.active(in: sessions).map(\.tool),
        equals: [.claude],
        "active tools"
    )
}

func testToolSummaryReportsWorstStatusForSemaphore() throws {
    let working = try AgentSession.decode(from: validStateJSON(sessionID: "w", status: "working"))
    let idle = try AgentSession.decode(from: validStateJSON(sessionID: "i", status: "idle"))
    let attention = try AgentSession.decode(
        from: validStateJSON(sessionID: "a", status: "needs_attention")
    )

    try expect(
        ToolSummary(tool: .claude, sessions: [working]).worstStatus,
        equals: .working,
        "all working stays green"
    )
    try expect(
        ToolSummary(tool: .claude, sessions: [working, idle]).worstStatus,
        equals: .idle,
        "one idle turns yellow"
    )
    try expect(
        ToolSummary(tool: .claude, sessions: [working, idle, attention]).worstStatus,
        equals: .needsAttention,
        "one attention turns red"
    )
    try expect(
        ToolSummary(tool: .claude, sessions: []).worstStatus,
        equals: nil,
        "no sessions, no semaphore"
    )
}

func testNotchWingPlacementSplitsToolsAroundNotch() throws {
    let sessions = [
        try AgentSession.decode(from: validStateJSON(sessionID: "c1", status: "working")),
        try AgentSession.decode(
            from: validStateJSON(sessionID: "o1", status: "idle", tool: "opencode")
        ),
        try AgentSession.decode(
            from: validStateJSON(sessionID: "x1", status: "working", tool: "codex")
        ),
        try AgentSession.decode(
            from: validStateJSON(sessionID: "p1", status: "working", tool: "pi")
        ),
        try AgentSession.decode(
            from: validStateJSON(sessionID: "v1", status: "working", tool: "convoy")
        ),
    ]

    let placement = NotchWingPlacement.place(ToolSummary.active(in: sessions))

    try expect(
        placement.leftWing.map(\.tool),
        equals: [.convoy, .pi, .codex, .opencode],
        "left wing order"
    )
    try expect(placement.rightWing.map(\.tool), equals: [.claude], "right wing")

    let opencodeOnly = NotchWingPlacement.place(
        ToolSummary.active(in: [sessions[1]])
    )
    try expect(opencodeOnly.leftWing.map(\.tool), equals: [.opencode], "left wing solo opencode")
    try expect(opencodeOnly.rightWing.isEmpty, equals: true, "right wing empty")
}

func testAttentionAcknowledgmentsSilenceVisitedSessionsUntilNewActivity() throws {
    let waiting = try AgentSession.decode(
        from: validStateJSON(sessionID: "ack", status: "needs_attention")
    )
    var acknowledgments = AttentionAcknowledgments()

    try expect(
        ToolSummary.active(in: acknowledgments.silenced([waiting])).first?.worstStatus,
        equals: .needsAttention,
        "unvisited session keeps its red light"
    )

    acknowledgments.acknowledge(waiting)
    try expect(
        ToolSummary.active(in: acknowledgments.silenced([waiting])).first?.worstStatus,
        equals: .working,
        "visited session goes quiet in the bar"
    )
    try expect(
        acknowledgments.silenced([waiting]).first?.sessionID,
        equals: "ack",
        "silencing keeps the session listed"
    )

    let reraised = AgentSession(
        tool: waiting.tool,
        sessionID: waiting.sessionID,
        pid: waiting.pid,
        status: .needsAttention,
        cwd: waiting.cwd,
        startedAt: waiting.startedAt,
        updatedAt: waiting.updatedAt.addingTimeInterval(60),
        terminal: waiting.terminal
    )
    try expect(
        ToolSummary.active(in: acknowledgments.silenced([reraised])).first?.worstStatus,
        equals: .needsAttention,
        "new activity re-arms the light"
    )
}

func testGitWorkspaceInspectorResolvesBranchNames() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let filesystem = FileManager.default

    let repo = root.appendingPathComponent("repo", isDirectory: true)
    try filesystem.createDirectory(
        at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true
    )
    try Data("ref: refs/heads/feat/notch-menu\n".utf8)
        .write(to: repo.appendingPathComponent(".git/HEAD"))
    try expect(
        GitWorkspaceInspector.branchName(forWorkingDirectory: repo.path),
        equals: "feat/notch-menu",
        "branch of a normal repository"
    )

    let nested = repo.appendingPathComponent("deep/subdir", isDirectory: true)
    try filesystem.createDirectory(at: nested, withIntermediateDirectories: true)
    try expect(
        GitWorkspaceInspector.branchName(forWorkingDirectory: nested.path),
        equals: "feat/notch-menu",
        "branch found walking up from a subdirectory"
    )

    let worktreeMetadata = repo.appendingPathComponent(".git/worktrees/glance", isDirectory: true)
    try filesystem.createDirectory(at: worktreeMetadata, withIntermediateDirectories: true)
    try Data("ref: refs/heads/fix/menu\n".utf8)
        .write(to: worktreeMetadata.appendingPathComponent("HEAD"))
    let linkedWorktree = root.appendingPathComponent("repo.fix-menu", isDirectory: true)
    try filesystem.createDirectory(at: linkedWorktree, withIntermediateDirectories: true)
    try Data("gitdir: \(worktreeMetadata.path)\n".utf8)
        .write(to: linkedWorktree.appendingPathComponent(".git"))
    try expect(
        GitWorkspaceInspector.branchName(forWorkingDirectory: linkedWorktree.path),
        equals: "fix/menu",
        "branch of a linked worktree"
    )

    let detached = root.appendingPathComponent("detached", isDirectory: true)
    try filesystem.createDirectory(
        at: detached.appendingPathComponent(".git"), withIntermediateDirectories: true
    )
    try Data("0123456789abcdef0123456789abcdef01234567\n".utf8)
        .write(to: detached.appendingPathComponent(".git/HEAD"))
    try expect(
        GitWorkspaceInspector.branchName(forWorkingDirectory: detached.path),
        equals: "0123456",
        "short hash for a detached HEAD"
    )

    let bare = root.appendingPathComponent("not-a-repo", isDirectory: true)
    try filesystem.createDirectory(at: bare, withIntermediateDirectories: true)
    try expect(
        GitWorkspaceInspector.branchName(forWorkingDirectory: bare.path),
        equals: nil,
        "nil outside any repository"
    )
}

func testNotchLayoutExtendsFromLeftSideOfHardwareNotch() throws {
    let layout = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 666,
        rightNotchEdgeX: 846
    )

    try expect(layout.width, equals: 432, "maximum panel width")
    try expect(layout.height, equals: 38, "collapsed panel height")
    try expect(layout.expandedHeight, equals: 398, "expanded panel height")
    try expect(layout.originX, equals: 484, "panel x")
    try expect(layout.originY, equals: 944, "panel y")
    try expect(layout.contentTopPadding, equals: 7, "content top padding")
    try expect(layout.leftContentWidth, equals: 182, "maximum left wing width")
    try expect(layout.rightContentWidth, equals: 70, "maximum right wing width")
    try expect(layout.notchWidth, equals: 180, "hardware notch width")
    try expect(NotchLayout.wingWidth(activeToolCount: 1), equals: 70, "one-tool wing")
    try expect(NotchLayout.wingWidth(activeToolCount: 2), equals: 126, "two-tool wing")
    try expect(NotchLayout.wingWidth(activeToolCount: 3), equals: 182, "three-tool wing")
}

func testOpenCodePluginWritesSessionState() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pluginURL = directory.appendingPathComponent("agentglance.mjs")
    try FileManager.default.copyItem(at: BundledResources.opencodePluginURL, to: pluginURL)
    let driver = directory.appendingPathComponent("driver.mjs")
    try Data(
        """
        import { AgentGlancePlugin } from "\(pluginURL.absoluteString)";
        const plugin = await AgentGlancePlugin({
          directory: "/tmp/open-project",
          client: { app: { log: async ({ body }) => console.error(body.message) } }
        });
        await plugin.event({ event: {
          type: "session.created",
          properties: { info: { id: "open-1", directory: "/tmp/open-project" } }
        }});
        """.utf8
    ).write(to: driver)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", driver.path]
    process.environment = [
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        "AGENTGLANCE_HOME": directory.path,
        "TERM_PROGRAM": "ghostty",
    ]
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let errorOutput = String(
        data: errors.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    try expect(process.terminationStatus, equals: 0, "plugin process: \(errorOutput)")
    let stateDirectory = directory.appendingPathComponent("state")
    let stateFiles = (try? FileManager.default.contentsOfDirectory(atPath: stateDirectory.path)) ?? []
    let session = try StateRepository(directoryURL: stateDirectory)
        .loadSessions().first.unwrap(or: "opencode state was not saved; files: \(stateFiles)")
    try expect(session.tool, equals: .opencode, "tool")
    try expect(session.status, equals: .working, "status")
    try expect(session.terminal.termProgram, equals: "ghostty", "terminal program")
}

func testOpenCodePluginMapsLifecycleEvents() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pluginURL = directory.appendingPathComponent("agentglance.mjs")
    try FileManager.default.copyItem(at: BundledResources.opencodePluginURL, to: pluginURL)
    let driver = directory.appendingPathComponent("lifecycle.mjs")
    try Data(
        """
        import { readFile } from "node:fs/promises";
        import { AgentGlancePlugin } from "\(pluginURL.absoluteString)";
        const plugin = await AgentGlancePlugin({
          directory: "/tmp/project",
          client: { app: { log: async ({ body }) => console.error(body.message) } }
        });
        const event = async (type, properties) => plugin.event({ event: { type, properties } });
        const statuses = [];
        const capture = async () => statuses.push(JSON.parse(
          await readFile(`${process.env.AGENTGLANCE_HOME}/state/opencode-b3Blbi0x.json`, "utf8")
        ));
        await event("session.created", { info: { id: "open-1", directory: "/tmp/project" } });
        await event("permission.asked", { sessionID: "open-1" }); await capture();
        await event("permission.replied", { sessionID: "open-1" }); await capture();
        await event("session.idle", { sessionID: "open-1" }); await capture();
        await event("session.deleted", { info: { id: "open-1" } }); await capture();
        console.log(JSON.stringify(statuses));
        """.utf8
    ).write(to: driver)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", driver.path]
    process.environment = [
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        "AGENTGLANCE_HOME": directory.path,
    ]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    try expect(process.terminationStatus, equals: 0, "plugin lifecycle process")
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let states = try decoder.decode([AgentSession].self, from: data)
    try expect(
        states.map(\.status),
        equals: [.needsAttention, .working, .idle, .ended],
        "lifecycle statuses"
    )
}

func testPiExtensionWritesSessionState() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let extensionURL = directory.appendingPathComponent("agentglance.mjs")
    try FileManager.default.copyItem(at: BundledResources.piExtensionURL, to: extensionURL)
    let driver = directory.appendingPathComponent("driver.mjs")
    try Data(
        """
        import agentGlance from "\(extensionURL.absoluteString)";
        const handlers = new Map();
        agentGlance({ on: (event, handler) => handlers.set(event, handler) });
        const ctx = {
          cwd: "/tmp/pi-project",
          sessionManager: { getSessionId: () => "pi-1" },
        };
        await handlers.get("session_start")({ reason: "start" }, ctx);
        """.utf8
    ).write(to: driver)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", driver.path]
    process.environment = [
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        "AGENTGLANCE_HOME": directory.path,
        "TERM_PROGRAM": "ghostty",
    ]
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let errorOutput = String(
        data: errors.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    try expect(process.terminationStatus, equals: 0, "extension process: \(errorOutput)")
    let session = try StateRepository(directoryURL: directory.appendingPathComponent("state"))
        .loadSessions().first.unwrap(or: "pi state was not saved")
    try expect(session.tool, equals: .pi, "tool")
    try expect(session.status, equals: .working, "status")
    try expect(session.cwd, equals: "/tmp/pi-project", "cwd")
    try expect(session.terminal.termProgram, equals: "ghostty", "terminal program")
}

func testPiExtensionMapsLifecycleEvents() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let extensionURL = directory.appendingPathComponent("agentglance.mjs")
    try FileManager.default.copyItem(at: BundledResources.piExtensionURL, to: extensionURL)
    let driver = directory.appendingPathComponent("lifecycle.mjs")
    try Data(
        """
        import { readFile } from "node:fs/promises";
        import agentGlance from "\(extensionURL.absoluteString)";
        const handlers = new Map();
        agentGlance({ on: (event, handler) => handlers.set(event, handler) });
        const ctx = {
          cwd: "/tmp/pi-project",
          sessionManager: { getSessionId: () => "pi-1" },
        };
        const fire = async (event, payload = {}) => handlers.get(event)(payload, ctx);
        const states = [];
        const capture = async () => states.push(JSON.parse(
          await readFile(`${process.env.AGENTGLANCE_HOME}/state/pi-cGktMQ.json`, "utf8")
        ));
        await fire("session_start", { reason: "start" });
        await fire("agent_start"); await capture();
        await fire("agent_end", { messages: [] }); await capture();
        await fire("input", { text: "next prompt" }); await capture();
        await fire("session_shutdown", { reason: "exit" }); await capture();
        console.log(JSON.stringify(states));
        """.utf8
    ).write(to: driver)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", driver.path]
    process.environment = [
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        "AGENTGLANCE_HOME": directory.path,
    ]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    try expect(process.terminationStatus, equals: 0, "extension lifecycle process")
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let states = try decoder.decode([AgentSession].self, from: data)
    try expect(
        states.map(\.status),
        equals: [.working, .idle, .working, .ended],
        "lifecycle statuses"
    )
    try expect(
        states.map(\.attentionReason),
        equals: [nil, .turnComplete, nil, nil],
        "attention reasons"
    )
}

func testCodexRolloutParserMapsSessionAndTurnEvents() throws {
    var parser = CodexRolloutParser(processID: 321)
    let lines = [
        #"{"timestamp":"2026-07-18T10:00:00Z","type":"session_meta","payload":{"id":"codex-1","cwd":"/tmp/codex-project","timestamp":"2026-07-18T10:00:00Z"}}"#,
        #"{"timestamp":"2026-07-18T10:00:01Z","type":"event_msg","payload":{"type":"task_started"}}"#,
        #"{"timestamp":"2026-07-18T10:00:02Z","type":"event_msg","payload":{"type":"exec_approval_request"}}"#,
        #"{"timestamp":"2026-07-18T10:00:03Z","type":"event_msg","payload":{"type":"exec_command_begin"}}"#,
        #"{"timestamp":"2026-07-18T10:00:04Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
    ]

    let states = lines.compactMap { parser.consume(line: Data($0.utf8)) }

    try expect(states.map(\.status), equals: [
        .working,
        .working,
        .needsAttention,
        .working,
        .idle,
    ], "Codex states")
    try expect(states.first?.sessionID, equals: "codex-1", "session ID")
    try expect(states.first?.cwd, equals: "/tmp/codex-project", "cwd")
}

func testCodexRolloutParserIgnoresMalformedAndUnknownLines() throws {
    var parser = CodexRolloutParser(processID: 321)

    let malformed = parser.consume(line: Data("not-json".utf8))
    let unknown = parser.consume(
        line: Data(#"{"timestamp":"2026-07-18T10:00:00Z","type":"future_event","payload":{}}"#.utf8)
    )

    try expect(malformed == nil, equals: true, "malformed line")
    try expect(unknown == nil, equals: true, "unknown line")
}

func testCodexSessionsWatcherProcessesAppendedLinesIncrementally() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sessionsDirectory = root.appendingPathComponent("sessions", isDirectory: true)
    let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let rollout = sessionsDirectory.appendingPathComponent("rollout.jsonl")
    let metadata = #"{"timestamp":"2026-07-18T10:00:00Z","type":"session_meta","payload":{"id":"codex-watch","cwd":"/tmp/watched","timestamp":"2026-07-18T10:00:00Z"}}"#
    try Data("\(metadata)\n".utf8).write(to: rollout)
    let repository = StateRepository(directoryURL: stateDirectory)
    let watcher = CodexSessionsWatcher(
        sessionsDirectoryURL: sessionsDirectory,
        repository: repository,
        processID: Int32(getpid())
    )

    try watcher.scan()
    let approval = #"{"timestamp":"2026-07-18T10:00:01Z","type":"event_msg","payload":{"type":"request_permissions"}}"#
    let handle = try FileHandle(forWritingTo: rollout)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("\(approval)\n".utf8))
    try handle.close()
    try watcher.scan()

    let session = try repository.loadSessions().first.unwrap(or: "Codex state was not saved")
    try expect(session.status, equals: .needsAttention, "appended event status")
    try expect(session.attentionReason, equals: .permission, "appended event reason")
}

func testCodexSessionsWatcherResavesWhenProcessAppearsLater() throws {
    // A rollout's session_meta can be ingested before the scanner has seen
    // the codex process. Retargeting the resolver must publish the
    // already-parsed session without waiting for new rollout bytes —
    // recreating the watcher (the old behavior) re-read entire files.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sessionsDirectory = root.appendingPathComponent("sessions", isDirectory: true)
    let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let metadata = #"{"timestamp":"2026-07-18T10:00:00Z","type":"session_meta","payload":{"id":"codex-late","cwd":"/tmp/late-bound","timestamp":"2026-07-18T10:00:00Z"}}"#
    try Data("\(metadata)\n".utf8).write(to: sessionsDirectory.appendingPathComponent("rollout.jsonl"))
    let repository = StateRepository(directoryURL: stateDirectory)
    let watcher = CodexSessionsWatcher(
        sessionsDirectoryURL: sessionsDirectory,
        repository: repository,
        processIDResolver: { _ in nil }
    )

    try watcher.scan()
    try expect(
        try repository.loadSessions().isEmpty,
        equals: true,
        "unresolved session stays unpublished"
    )

    watcher.processIDResolver = { _ in Int32(getpid()) }
    try watcher.scan()

    let session = try repository.loadSessions().first.unwrap(or: "session was not published")
    try expect(session.sessionID, equals: "codex-late", "published session identity")
    try expect(session.pid, equals: Int32(getpid()), "session adopts the resolved pid")
}

func testCodexSessionsWatcherSkipsDateDirectoriesOutsideWindow() throws {
    // Codex stores rollouts under YYYY/MM/DD directories and the tree grows
    // without bound. Directories whose date period ends before the
    // ingestion window must be skipped without visiting their contents,
    // even when file mtimes are recent (a copied or restored tree).
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sessionsDirectory = root.appendingPathComponent("sessions", isDirectory: true)
    let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
    let oldDirectory = sessionsDirectory.appendingPathComponent("2020/01/01", isDirectory: true)
    try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let oldMetadata = #"{"timestamp":"2026-07-18T10:00:00Z","type":"session_meta","payload":{"id":"codex-old","cwd":"/tmp/old","timestamp":"2026-07-18T10:00:00Z"}}"#
    try Data("\(oldMetadata)\n".utf8).write(to: oldDirectory.appendingPathComponent("rollout.jsonl"))
    let currentMetadata = #"{"timestamp":"2026-07-18T10:00:00Z","type":"session_meta","payload":{"id":"codex-current","cwd":"/tmp/current","timestamp":"2026-07-18T10:00:00Z"}}"#
    try Data("\(currentMetadata)\n".utf8).write(to: sessionsDirectory.appendingPathComponent("rollout.jsonl"))
    let repository = StateRepository(directoryURL: stateDirectory)
    let watcher = CodexSessionsWatcher(
        sessionsDirectoryURL: sessionsDirectory,
        repository: repository,
        processID: Int32(getpid()),
        ingestionWindow: 3600
    )

    try watcher.scan()

    let sessionIDs = Set(try repository.loadSessions().map(\.sessionID))
    try expect(sessionIDs, equals: ["codex-current"], "only in-window rollouts are ingested")
}

func writeConvoyRunFixture(
    at runsDirectoryURL: URL,
    runID: String,
    serverPid: Int32,
    serverStartedAt: Date,
    targetDir: String = "/tmp/convoy-target",
    phases: [(name: String, status: String, sessionID: String?)],
    humanSteps: Set<String> = []
) throws {
    let phaseEntries = phases.map { phase in
        let sessionIDField = phase.sessionID.map { "\"sessionID\": \"\($0)\"," } ?? ""
        return """
        "\(phase.name)": {
          "status": "\(phase.status)",
          \(sessionIDField)
          "startedAt": \(Int(serverStartedAt.timeIntervalSince1970 * 1000))
        }
        """
    }.joined(separator: ",\n")
    let steps = phases.map { phase in
        """
        {"type": "\(humanSteps.contains(phase.name) ? "human" : "agent")", "name": "\(phase.name)"}
        """
    }.joined(separator: ",\n")
    let metadata = """
    {
      "schemaVersion": 2,
      "runID": "\(runID)",
      "targetDir": "\(targetDir)",
      "createdAt": \(Int(serverStartedAt.timeIntervalSince1970 * 1000)),
      "updatedAt": \(Int(Date().timeIntervalSince1970 * 1000)),
      "server": {
        "url": "http://127.0.0.1:4096",
        "pid": \(serverPid),
        "startedAt": \(Int(serverStartedAt.timeIntervalSince1970 * 1000))
      },
      "phases": { \(phaseEntries) },
      "pipeline": { "name": "test", "steps": [ \(steps) ] }
    }
    """
    let runDirectoryURL = runsDirectoryURL.appendingPathComponent(runID, isDirectory: true)
    try FileManager.default.createDirectory(at: runDirectoryURL, withIntermediateDirectories: true)
    try Data(metadata.utf8).write(to: runDirectoryURL.appendingPathComponent("metadata.json"))
}

func makeConvoyTestDirectories() throws -> (stateDirectoryURL: URL, runsDirectoryURL: URL) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let state = base.appendingPathComponent("state", isDirectory: true)
    let runs = base.appendingPathComponent("runs", isDirectory: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
    return (state, runs)
}

func detectedConvoyProcess(elapsedSeconds: TimeInterval = 600) -> DetectedAgentProcess {
    DetectedAgentProcess(
        tool: .convoy,
        processID: Int32(getpid()),
        cwd: "/tmp/convoy-target",
        terminal: TerminalContext(termProgram: "ghostty", tty: "/dev/ttys009"),
        elapsedSeconds: elapsedSeconds
    )
}

func testConvoyWatcherPublishesRunningPipelineStep() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: "20260719-101010-abcd",
        serverPid: Int32(getpid()),
        serverStartedAt: Date().addingTimeInterval(-300),
        phases: [
            ("scope", "completed", "ses_scope"),
            ("security", "running", "ses_security"),
        ]
    )
    let watcher = ConvoyRunsWatcher(runsDirectoryURL: runsDirectoryURL, repository: repository)

    try watcher.scan(detected: [detectedConvoyProcess()])

    let session = try repository.loadSessions().first.unwrap(or: "no convoy session was published")
    try expect(session.tool, equals: .convoy, "tool")
    try expect(session.sessionID, equals: "20260719-101010-abcd", "session ID")
    try expect(session.pid, equals: Int32(getpid()), "pid")
    try expect(session.status, equals: .working, "status")
    try expect(session.currentStep, equals: "security", "current step")
    try expect(session.cwd, equals: "/tmp/convoy-target", "cwd")
    try expect(session.terminal.termProgram, equals: "ghostty", "terminal context adopted")
}

func testConvoyWatcherFlagsWaitingHumanGate() throws {
    // A human gate reports itself as a running phase, but the pipeline is
    // actually paused waiting for the user — the semaphore must go red,
    // never green (the same trap Claude's SessionStart used to fall into).
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: "20260719-111111-gate",
        serverPid: Int32(getpid()),
        serverStartedAt: Date().addingTimeInterval(-300),
        phases: [
            ("implementer", "completed", "ses_impl"),
            ("human-review", "running", nil),
        ],
        humanSteps: ["human-review"]
    )
    let watcher = ConvoyRunsWatcher(runsDirectoryURL: runsDirectoryURL, repository: repository)

    try watcher.scan(detected: [detectedConvoyProcess()])

    let session = try repository.loadSessions().first.unwrap(or: "no convoy session was published")
    try expect(session.status, equals: .needsAttention, "status")
    try expect(session.attentionReason, equals: .permission, "attention reason")
    try expect(session.currentStep, equals: "human-review", "current step")
}

func testConvoyWatcherMapsTerminalPipelineStates() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    let watcher = ConvoyRunsWatcher(runsDirectoryURL: runsDirectoryURL, repository: repository)

    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: "20260719-121212-fail",
        serverPid: Int32(getpid()),
        serverStartedAt: Date().addingTimeInterval(-300),
        phases: [("implementer", "completed", "ses_impl"), ("tests", "failed", "ses_tests")]
    )
    try watcher.scan(detected: [detectedConvoyProcess()])
    let failed = try repository.loadSessions().first.unwrap(or: "failed run was not published")
    try expect(failed.status, equals: .needsAttention, "failed status")
    try expect(failed.attentionReason, equals: .turnComplete, "failed attention reason")
    try expect(failed.currentStep, equals: "tests failed", "failed step")

    try repository.remove(failed)
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: "20260719-131313-done",
        serverPid: Int32(getpid()),
        serverStartedAt: Date().addingTimeInterval(-200),
        phases: [("implementer", "completed", "ses_impl"), ("tests", "completed", "ses_tests")]
    )
    try watcher.scan(detected: [detectedConvoyProcess()])
    let finished = try repository.loadSessions().first.unwrap(or: "finished run was not published")
    try expect(finished.sessionID, equals: "20260719-131313-done", "newest run wins")
    try expect(finished.status, equals: .idle, "finished status")
    try expect(finished.currentStep, equals: nil, "finished step")
}

func testConvoyWatcherIgnoresRunsNotOwnedByLiveProcess() throws {
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    let watcher = ConvoyRunsWatcher(runsDirectoryURL: runsDirectoryURL, repository: repository)

    // A historical run whose recorded server pid now belongs to a live
    // convoy process (pid recycling) must not resurrect: its server started
    // long before the process did.
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: "20260601-090909-old",
        serverPid: Int32(getpid()),
        serverStartedAt: Date().addingTimeInterval(-86_400),
        phases: [("security", "running", "ses_old")]
    )
    // A run recorded by some other process entirely.
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: "20260719-141414-othr",
        serverPid: 999_999,
        serverStartedAt: Date().addingTimeInterval(-60),
        phases: [("security", "running", "ses_other")]
    )

    try watcher.scan(detected: [detectedConvoyProcess(elapsedSeconds: 600)])

    try expect(try repository.loadSessions().isEmpty, equals: true, "no session published")
}

func testConvoyWatcherSuppressesPipelineOwnedOpenCodeSessions() throws {
    // Convoy phases run as OpenCode sessions on convoy's embedded server;
    // if that server loads the AgentGlance plugin, each phase would also
    // surface as a standalone OpenCode row next to the pipeline it belongs
    // to. The run metadata names those session IDs, so they are removed.
    let (stateDirectoryURL, runsDirectoryURL) = try makeConvoyTestDirectories()
    defer { try? FileManager.default.removeItem(at: stateDirectoryURL.deletingLastPathComponent()) }
    let repository = StateRepository(directoryURL: stateDirectoryURL)
    try repository.save(AgentSession.decode(
        from: validStateJSON(sessionID: "ses_security", status: "working", pid: Int32(getpid()), tool: "opencode")
    ))
    try repository.save(AgentSession.decode(
        from: validStateJSON(sessionID: "ses_unrelated", status: "idle", pid: Int32(getpid()), tool: "opencode")
    ))
    try writeConvoyRunFixture(
        at: runsDirectoryURL,
        runID: "20260719-151515-supp",
        serverPid: Int32(getpid()),
        serverStartedAt: Date().addingTimeInterval(-300),
        phases: [("security", "running", "ses_security")]
    )
    let watcher = ConvoyRunsWatcher(runsDirectoryURL: runsDirectoryURL, repository: repository)

    try watcher.scan(detected: [detectedConvoyProcess()])

    let opencodeSessionIDs = try repository.loadSessions()
        .filter { $0.tool == .opencode }
        .map(\.sessionID)
    try expect(opencodeSessionIDs, equals: ["ses_unrelated"], "surviving opencode sessions")
}

func testFocusPlannerPrioritizesTmuxThenTerminal() throws {
    let data = Data(
        #"{"schema_version":1,"tool":"claude","session_id":"focus","pid":1,"status":"working","attention_reason":null,"cwd":"/tmp/project","started_at":"2026-07-18T10:00:00Z","updated_at":"2026-07-18T10:00:00Z","terminal":{"term_program":"ghostty","ghostty_terminal_id":"terminal-123","tmux_pane":"%3","window_title_hint":"project — claude"}}"#.utf8
    )
    let session = try AgentSession.decode(from: data)

    let actions = try FocusPlanner.actions(for: session)

    try expect(
        actions.first,
        equals: .run(executable: "tmux", arguments: ["select-window", "-t", "%3"]),
        "first focus action"
    )
    guard actions.contains(where: { action in
        if case let .appleScript(script) = action {
            return script.contains("Ghostty") && script.contains("terminal-123")
        }
        return false
    }) else {
        throw TestFailure.expectation("Ghostty focus action is missing")
    }
}

func testGhosttyMatcherExcludesOrphanedProcessesAndAssignsExactTerminals() throws {
    let processes = [
        detectedProcess(id: 1, cwd: "/stale-one", elapsed: 1_000),
        detectedProcess(id: 2, cwd: "/visible-one", elapsed: 500),
        detectedProcess(id: 3, cwd: "/visible-two", elapsed: 400),
        detectedProcess(id: 4, cwd: "/stale-two", elapsed: 2_000),
        detectedProcess(id: 5, cwd: "/current", elapsed: 10),
    ]
    let terminals = [
        GhosttyTerminal(id: "one", name: "Visible one", cwd: "/visible-one"),
        GhosttyTerminal(id: "two", name: "Visible two", cwd: "/visible-two"),
        GhosttyTerminal(id: "current", name: "Current agent", cwd: ""),
    ]

    let matched = GhosttySessionMatcher.match(processes: processes, terminals: terminals)

    try expect(matched.map(\.processID).sorted(), equals: [2, 3, 5], "visible process IDs")
    try expect(
        matched.first(where: { $0.processID == 5 })?.terminal.ghosttyTerminalID,
        equals: "current",
        "exact terminal ID"
    )
}

func testGhosttyMatcherPrefersSameDirectoryTerminalNamingTheTool() throws {
    // Several tabs often share one project directory (claude and opencode
    // side by side). The tab whose title names the tool must win, so the
    // session row shows — and focus jumps to — the right tab.
    let processes = [
        DetectedAgentProcess(
            tool: .opencode,
            processID: 21,
            cwd: "/tmp/shared-project",
            terminal: TerminalContext(termProgram: "ghostty"),
            elapsedSeconds: 10
        ),
        DetectedAgentProcess(
            tool: .claude,
            processID: 22,
            cwd: "/tmp/shared-project",
            terminal: TerminalContext(termProgram: "ghostty"),
            elapsedSeconds: 20
        ),
    ]
    let terminals = [
        GhosttyTerminal(id: "claude-tab", name: "shared-project — claude", cwd: "/tmp/shared-project"),
        GhosttyTerminal(id: "opencode-tab", name: "shared-project — opencode", cwd: "/tmp/shared-project"),
    ]

    let matched = GhosttySessionMatcher.match(processes: processes, terminals: terminals)

    try expect(
        matched.first(where: { $0.tool == .opencode })?.terminal.ghosttyTerminalID,
        equals: "opencode-tab",
        "opencode terminal"
    )
    try expect(
        matched.first(where: { $0.tool == .claude })?.terminal.ghosttyTerminalID,
        equals: "claude-tab",
        "claude terminal"
    )
}

func detectedProcess(id: Int32, cwd: String, elapsed: TimeInterval) -> DetectedAgentProcess {
    DetectedAgentProcess(
        tool: .opencode,
        processID: id,
        cwd: cwd,
        terminal: TerminalContext(termProgram: "ghostty", tty: "/dev/ttys\(id)"),
        elapsedSeconds: elapsed
    )
}

struct SpawnedFakeAgent {
    let rootDirectory: URL
    let process: Process
    let expectedWorkingDirectory: String

    func tearDown() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}

/// Launches a real long-running process whose executable basename matches an
/// agent tool, inside a working directory we control, so scanner tests observe
/// genuine system behavior instead of fixtures. When `underFakeTerminalApp`
/// is set (for example "Ghostty.app"), the agent runs as the child of a shell
/// whose argv[0] lives inside that bundle path, emulating a terminal host.
func spawnFakeAgent(
    named executableName: String,
    underFakeTerminalApp terminalAppName: String? = nil
) throws -> SpawnedFakeAgent {
    let fileManager = FileManager.default
    let rootDirectory = fileManager.temporaryDirectory
        .appendingPathComponent("agentglance-scanner-\(UUID().uuidString)", isDirectory: true)
    let binDirectory = rootDirectory.appendingPathComponent("bin", isDirectory: true)
    let projectDirectory = rootDirectory.appendingPathComponent("project dir", isDirectory: true)
    try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)

    // A symlink keeps /bin/sleep valid as a platform binary (copies get
    // SIGKILLed on Apple Silicon) and mirrors real versioned installs such as
    // ~/.local/bin/claude -> .../versions/2.1.214: the kernel-resolved
    // executable path is "sleep" while argv[0] carries the agent name.
    let executable = binDirectory.appendingPathComponent(executableName)
    try fileManager.createSymbolicLink(
        at: executable,
        withDestinationURL: URL(fileURLWithPath: "/bin/sleep")
    )

    let process = Process()
    if let terminalAppName {
        let hostDirectory = rootDirectory.appendingPathComponent(
            "\(terminalAppName)/Contents/MacOS",
            isDirectory: true
        )
        try fileManager.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
        let hostShell = hostDirectory.appendingPathComponent("host-shell")
        try fileManager.createSymbolicLink(
            at: hostShell,
            withDestinationURL: URL(fileURLWithPath: "/bin/zsh")
        )
        process.executableURL = hostShell
        // The trailing builtin keeps zsh alive as the parent instead of
        // exec-replacing itself with the agent.
        process.arguments = ["-c", #""$0" 300; :"#, executable.path]
    } else {
        process.executableURL = executable
        process.arguments = ["300"]
    }
    process.currentDirectoryURL = projectDirectory
    try process.run()

    // realpath(3) instead of URL.resolvingSymlinksInPath(), which strips the
    // /private prefix the kernel reports for temporary directories.
    guard let resolvedPath = realpath(projectDirectory.path, nil) else {
        throw TestFailure.expectation("could not canonicalize fake project directory")
    }
    defer { free(resolvedPath) }
    return SpawnedFakeAgent(
        rootDirectory: rootDirectory,
        process: process,
        expectedWorkingDirectory: String(cString: resolvedPath)
    )
}

func testGhosttyTerminalQueryCacheAvoidsRedundantQueries() throws {
    final class QueryCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            defer { lock.unlock() }
            value += 1
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
    let counter = QueryCounter()
    let terminals = [GhosttyTerminal(id: "1", name: "tab", cwd: "/tmp/project")]
    let cache = GhosttyTerminalQueryCache(timeToLive: 30) {
        counter.increment()
        return terminals
    }
    let start = Date(timeIntervalSince1970: 1_000_000)

    try expect(
        cache.terminals(hostingProcessIDs: [100], now: start),
        equals: terminals,
        "first query returns terminals"
    )
    try expect(
        cache.terminals(hostingProcessIDs: [100], now: start.addingTimeInterval(5)),
        equals: terminals,
        "fresh cache returns terminals"
    )
    try expect(counter.count, equals: 1, "fresh same-topology call is served from cache")
    _ = cache.terminals(hostingProcessIDs: [100, 200], now: start.addingTimeInterval(6))
    try expect(counter.count, equals: 2, "a topology change refreshes immediately")
    _ = cache.terminals(hostingProcessIDs: [100, 200], now: start.addingTimeInterval(60))
    try expect(counter.count, equals: 3, "an expired cache refreshes")

    let failureCounter = QueryCounter()
    let failingCache = GhosttyTerminalQueryCache(timeToLive: 30) {
        failureCounter.increment()
        return nil
    }
    _ = failingCache.terminals(hostingProcessIDs: [100], now: start)
    _ = failingCache.terminals(hostingProcessIDs: [100], now: start.addingTimeInterval(1))
    try expect(failureCounter.count, equals: 2, "failed queries are never cached")
}

func testProcessScannerDetectsSpawnedAgentProcessWithinBudget() throws {
    let agent = try spawnFakeAgent(named: "codex")
    defer { agent.tearDown() }

    let scanner = SystemProcessScanner(ghosttyTerminalSource: { nil })
    let scanStart = Date()
    let detected = try scanner.activeProcesses()
    let scanDuration = Date().timeIntervalSince(scanStart)

    guard let match = detected.first(where: { $0.processID == agent.process.processIdentifier }) else {
        throw TestFailure.expectation("spawned codex process was not detected")
    }
    try expect(match.tool, equals: .codex, "detected tool")
    try expect(match.cwd, equals: agent.expectedWorkingDirectory, "detected cwd")
    try expect(
        match.elapsedSeconds >= 0 && match.elapsedSeconds < 60,
        equals: true,
        "elapsed seconds should be a plausible age, got \(match.elapsedSeconds)"
    )
    try expect(
        scanDuration < 0.25,
        equals: true,
        "scan must stay within the 250ms budget, took \(scanDuration)s"
    )
}

func testProcessScannerDetectsScriptRuntimeAgents() throws {
    // Pi installs as an npm CLI: the kernel-resolved executable and argv[0]
    // both name the runtime (node), and the agent name only appears as the
    // script path in argv[1]. Modeled here with a fake "node" that runs a
    // script named "pi".
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("agentglance-runtime-\(UUID().uuidString)", isDirectory: true)
    let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
    try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let runtime = binDirectory.appendingPathComponent("node")
    try fileManager.createSymbolicLink(
        at: runtime,
        withDestinationURL: URL(fileURLWithPath: "/bin/zsh")
    )
    let script = binDirectory.appendingPathComponent("pi")
    try Data("/bin/sleep 300\n".utf8).write(to: script)
    let process = Process()
    process.executableURL = runtime
    process.arguments = [script.path]
    try process.run()
    defer {
        process.terminate()
        process.waitUntilExit()
    }

    var match: DetectedAgentProcess?
    let deadline = Date().addingTimeInterval(2)
    repeat {
        match = try SystemProcessScanner(ghosttyTerminalSource: { nil }).activeProcesses()
            .first { $0.processID == process.processIdentifier }
    } while match == nil && Date() < deadline

    try expect(
        match?.tool,
        equals: .pi,
        "a runtime-hosted script named pi must be detected as the pi agent"
    )
}

func testProcessScannerCollapsesRuntimeLauncherOntoNativeChild() throws {
    // npm's codex ships a node launcher (`node .../bin/codex`) that spawns
    // the platform binary (`.../codex-darwin-arm64/.../bin/codex`) as a
    // child. Both carry the tool name, but only the leaf process is the
    // agent — counting both shows two sessions for one Codex.
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("agentglance-launcher-\(UUID().uuidString)", isDirectory: true)
    let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
    let vendorDirectory = root.appendingPathComponent("vendor", isDirectory: true)
    try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: vendorDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let runtime = binDirectory.appendingPathComponent("node")
    try fileManager.createSymbolicLink(
        at: runtime,
        withDestinationURL: URL(fileURLWithPath: "/bin/zsh")
    )
    let nativeAgent = vendorDirectory.appendingPathComponent("codex")
    try fileManager.createSymbolicLink(
        at: nativeAgent,
        withDestinationURL: URL(fileURLWithPath: "/bin/sleep")
    )
    let launcherScript = binDirectory.appendingPathComponent("codex")
    // The trailing builtin keeps the fake node alive as the parent instead
    // of exec-replacing itself with the native agent.
    try Data("\"\(nativeAgent.path)\" 300; :\n".utf8).write(to: launcherScript)
    let launcher = Process()
    launcher.executableURL = runtime
    launcher.arguments = [launcherScript.path]
    try launcher.run()
    var nativeChildPID: pid_t?
    defer {
        launcher.terminate()
        launcher.waitUntilExit()
        if let nativeChildPID { kill(nativeChildPID, SIGTERM) }
    }

    let scanner = SystemProcessScanner(ghosttyTerminalSource: { nil })
    var codexProcesses: [DetectedAgentProcess] = []
    let deadline = Date().addingTimeInterval(2)
    func detectedNativeChild() -> pid_t? {
        codexProcesses.first {
            $0.processID != launcher.processIdentifier
                && SystemProcessScanner.parentProcessID(of: $0.processID) == launcher.processIdentifier
        }?.processID
    }
    repeat {
        codexProcesses = try scanner.activeProcesses().filter {
            $0.processID == launcher.processIdentifier
                || SystemProcessScanner.parentProcessID(of: $0.processID) == launcher.processIdentifier
        }
        if detectedNativeChild() == nil { usleep(50_000) }
    } while detectedNativeChild() == nil && Date() < deadline
    nativeChildPID = detectedNativeChild()

    try expect(
        codexProcesses.map(\.tool),
        equals: [.codex],
        "exactly one codex process must survive for one launcher+child pair"
    )
    try expect(
        codexProcesses.first?.processID != launcher.processIdentifier,
        equals: true,
        "the surviving process must be the native child, not the launcher"
    )
}

func testProcessScannerIgnoresLookalikeProcessNames() throws {
    let agent = try spawnFakeAgent(named: "codexx")
    defer { agent.tearDown() }

    let detected = try SystemProcessScanner(ghosttyTerminalSource: { nil }).activeProcesses()

    try expect(
        detected.contains { $0.processID == agent.process.processIdentifier },
        equals: false,
        "a lookalike executable name must not be detected as an agent"
    )
}

func testProcessScannerResolvesParentOfRootOwnedProcesses() throws {
    // Ghostty spawns shells through /usr/bin/login, which runs as root:
    // proc_pidinfo denies PROC_PIDTBSDINFO on other users' processes, so the
    // ancestor walk must fall back to the kinfo_proc sysctl (what ps uses).
    // launchd (pid 1, root-owned) exercises that path and has parent 0.
    try expect(
        SystemProcessScanner.parentProcessID(of: 1),
        equals: 0,
        "parent of root-owned launchd"
    )
    try expect(
        SystemProcessScanner.parentProcessID(of: getpid()),
        equals: getppid(),
        "parent of this process"
    )
}

func testProcessScannerIdentifiesHostTerminalFromAncestors() throws {
    let agent = try spawnFakeAgent(named: "codex", underFakeTerminalApp: "Ghostty.app")
    defer { agent.tearDown() }

    let scanner = SystemProcessScanner(ghosttyTerminalSource: { nil })
    var match: DetectedAgentProcess?
    let deadline = Date().addingTimeInterval(2)
    repeat {
        match = try scanner.activeProcesses().first {
            $0.tool == .codex && $0.cwd == agent.expectedWorkingDirectory
        }
        if match == nil { usleep(50_000) }
    } while match == nil && Date() < deadline
    guard let match else {
        throw TestFailure.expectation("agent under the fake terminal was not detected")
    }
    // The detected agent is the shell's child, not `agent.process`, so it
    // must be reaped explicitly or it would outlive the test.
    defer { kill(match.processID, SIGTERM) }

    try expect(match.terminal.termProgram, equals: "ghostty", "host terminal program")
}

func testClaudeSettingsMergePreservesHooksAndIsIdempotent() throws {
    let existing = Data(
        #"{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"existing-hook"}]}]}}"#.utf8
    )

    let once = try ClaudeSettingsMerger.merge(
        settingsData: existing,
        hookCommand: "/Users/me/.agentglance/bin/claude-hook.sh"
    )
    let twice = try ClaudeSettingsMerger.merge(
        settingsData: once,
        hookCommand: "/Users/me/.agentglance/bin/claude-hook.sh"
    )
    let json = try JSONSerialization.jsonObject(with: twice) as? [String: Any]
    let hooks = json?["hooks"] as? [String: [[String: Any]]]
    let stopGroups = hooks?["Stop"] ?? []
    let commands = stopGroups.flatMap { group in
        (group["hooks"] as? [[String: String]] ?? []).compactMap { $0["command"] }
    }

    try expect(json?["theme"] as? String, equals: "dark", "existing setting")
    try expect(commands.filter { $0 == "existing-hook" }.count, equals: 1, "existing hook")
    try expect(
        commands.filter { $0.contains("claude-hook.sh' 'Stop") }.count,
        equals: 1,
        "AgentGlance hook"
    )
}

func testClaudeSettingsRemovalPreservesUserHooks() throws {
    let installed = try ClaudeSettingsMerger.merge(
        settingsData: Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"mine"}]}]}}"#.utf8),
        hookCommand: "/tmp/claude-hook.sh"
    )

    let removed = try ClaudeSettingsMerger.remove(
        settingsData: installed,
        hookCommand: "/tmp/claude-hook.sh"
    )
    let text = String(data: removed, encoding: .utf8) ?? ""
    guard text.contains("mine"), !text.contains("/tmp/claude-hook.sh") else {
        throw TestFailure.expectation("unexpected settings after removal: \(text)")
    }
}

func testClaudeSettingsQuotesHookPathsForTheShell() throws {
    let installed = try ClaudeSettingsMerger.merge(
        settingsData: Data("{}".utf8),
        hookCommand: "/Users/O'Connor/My Tools/claude-hook.sh"
    )
    let root = try JSONSerialization.jsonObject(with: installed) as? [String: Any]
    let hooks = root?["hooks"] as? [String: [[String: Any]]]
    let commands = (hooks?["Stop"] ?? []).flatMap { group in
        (group["hooks"] as? [[String: String]] ?? []).compactMap { $0["command"] }
    }

    try expect(
        commands.first,
        equals: "'/Users/O'\\''Connor/My Tools/claude-hook.sh' 'Stop'",
        "shell-quoted hook command"
    )
}

func testInstallerRejectsSymlinkedPrivateDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home")
    let redirected = root.appendingPathComponent("redirected")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(
        at: home.appendingPathComponent(".agentglance"),
        withDestinationURL: redirected
    )

    do {
        try Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!).install()
        throw TestFailure.expectation("installer followed a symlinked private directory")
    } catch is InstallationError {
        try expect(
            try FileManager.default.contentsOfDirectory(atPath: redirected.path).isEmpty,
            equals: true,
            "redirected directory contents"
        )
    }
}

func testInstallerFollowsUserOwnedSymlinkedIntegrationDirectories() throws {
    // Dotfile setups routinely symlink ~/.config/opencode/plugins (or
    // ~/.claude) into a config repository inside the home directory. The
    // installer must follow those links when they resolve to a user-owned
    // directory under home — only ~/.agentglance is strictly symlink-free.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home")
    let dotfilesPlugins = home.appendingPathComponent("dotfiles/opencode-plugins")
    try FileManager.default.createDirectory(at: dotfilesPlugins, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: home.appendingPathComponent(".config/opencode"),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(
        at: home.appendingPathComponent(".config/opencode/plugins"),
        withDestinationURL: dotfilesPlugins
    )

    try Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!).install()

    try expect(
        FileManager.default.fileExists(
            atPath: dotfilesPlugins.appendingPathComponent("agentglance.js").path
        ),
        equals: true,
        "plugin lands in the symlink's resolved directory"
    )
    try expect(
        FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".claude/settings.json").path
        ),
        equals: true,
        "claude settings written"
    )
}

func testInstallerReplacesMarkedIntegrationFilesOnReinstall() throws {
    // Upgraded builds ship different plugin content, so exact-match
    // replacement alone would block every reinstall of our own files. The
    // ownership marker in the first line authorizes replacement; unmarked
    // files belong to the user and still refuse the install.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(
        at: home.appendingPathComponent(".config/opencode/plugins"),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let outdated = "// AgentGlance-managed integration; reinstalls replace this file.\nexport const Old = 1;\n"
    let pluginURL = home.appendingPathComponent(".config/opencode/plugins/agentglance.js")
    try Data(outdated.utf8).write(to: pluginURL)

    try Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!).install()

    try expect(
        try Data(contentsOf: pluginURL) == Data(contentsOf: BundledResources.opencodePluginURL),
        equals: true,
        "marked plugin is replaced by the bundled one"
    )

    let userExtensionURL = home.appendingPathComponent(".pi/agent/extensions/agentglance.ts")
    try Data("export default function mine() {}\n".utf8).write(to: userExtensionURL)
    do {
        try Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!).install()
        throw TestFailure.expectation("install must refuse an unmarked integration file")
    } catch let error as InstallationError {
        try expect(
            error,
            equals: .existingIntegrationFile(userExtensionURL.path),
            "unmarked files still refuse"
        )
    }
}

func testInstallerPrependsCodexNotifyBeforeExistingContent() throws {
    // A multi-line TOML value may continue on a line that begins with "[",
    // so inserting before the first such line can land inside a value. The
    // only position that is safe for a root-table key regardless of the
    // existing content is the top of the file.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(
        at: home.appendingPathComponent(".codex"),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let existingConfig = """
    targets = [
        ["a", "b"],
    ]

    [profiles.fast]
    model = "gpt-5"

    """
    let configURL = home.appendingPathComponent(".codex/config.toml")
    try Data(existingConfig.utf8).write(to: configURL)

    try Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!).install()

    let config = try String(contentsOf: configURL, encoding: .utf8)
    try expect(config.hasPrefix("notify = "), equals: true, "notify line leads the file")
    try expect(config.contains(existingConfig), equals: true, "existing content preserved verbatim")
}

func testInstallationDoctorReportsHealthyInstall() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!).install()

    let checks = InstallationDoctor(homeDirectoryURL: home).diagnose()

    try expect(checks.count, equals: 6, "doctor check count")
    for check in checks {
        try expect(check.passed, equals: true, "check '\(check.title)': \(check.detail)")
    }
    try expect(
        FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".pi/agent/extensions/agentglance.ts").path
        ),
        equals: true,
        "pi extension installed"
    )
}

func testInstallationDoctorPinpointsBrokenPieces() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Installer(homeDirectoryURL: home, executableURL: Bundle.main.executableURL!).install()
    try FileManager.default.removeItem(
        at: home.appendingPathComponent(".agentglance/bin/claude-hook.sh")
    )
    try Data("tampered".utf8).write(
        to: home.appendingPathComponent(".config/opencode/plugins/agentglance.js")
    )
    try Data("model = \"gpt-5\"\n".utf8).write(
        to: home.appendingPathComponent(".codex/config.toml")
    )
    try FileManager.default.removeItem(
        at: home.appendingPathComponent(".pi/agent/extensions/agentglance.ts")
    )

    let checks = InstallationDoctor(homeDirectoryURL: home).diagnose()
    let byTitle = Dictionary(uniqueKeysWithValues: checks.map { ($0.title, $0) })
    let binaries = try byTitle["hook binaries"].unwrap(or: "missing binaries check")
    let openCode = try byTitle["OpenCode plugin"].unwrap(or: "missing OpenCode check")
    let codex = try byTitle["Codex notify"].unwrap(or: "missing Codex check")

    try expect(binaries.passed, equals: false, "binaries check must fail")
    try expect(binaries.detail.contains("claude-hook.sh"), equals: true, "binaries detail names the missing script")
    try expect(openCode.passed, equals: false, "OpenCode check must fail")
    try expect(codex.passed, equals: false, "Codex check must fail")
    try expect(
        try byTitle["Pi extension"].unwrap(or: "missing Pi check").passed,
        equals: false,
        "Pi check must fail"
    )
    try expect(
        try byTitle["Claude Code hooks"].unwrap(or: "missing Claude check").passed,
        equals: true,
        "Claude hooks stay healthy"
    )
    try expect(
        try byTitle["state directory"].unwrap(or: "missing state check").passed,
        equals: true,
        "state directory stays healthy"
    )
}

func testFrontTerminalMatcherMatchesByIDAndFallsBackToWorkingDirectory() throws {
    func session(_ sessionID: String, terminalID: String?, cwd: String) -> AgentSession {
        AgentSession(
            tool: .claude,
            sessionID: sessionID,
            pid: 1,
            status: .idle,
            cwd: cwd,
            startedAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            terminal: TerminalContext(termProgram: "ghostty", ghosttyTerminalID: terminalID)
        )
    }
    let front = GhosttyFrontTerminal(terminalID: "77", workingDirectory: "/Users/me/project/")
    let exactMatch = session("exact", terminalID: "77", cwd: "/somewhere/else")
    let cwdFallback = session("fallback", terminalID: nil, cwd: "/Users/me/project")
    let otherTab = session("other-tab", terminalID: "12", cwd: "/Users/me/project")
    let otherDirectory = session("other-dir", terminalID: nil, cwd: "/Users/me/elsewhere")

    let focused = FrontTerminalMatcher.sessionsFocused(
        by: front,
        among: [exactMatch, cwdFallback, otherTab, otherDirectory]
    )

    try expect(
        focused.map(\.sessionID),
        equals: ["exact", "fallback"],
        "exact ID wins; missing ID falls back to cwd; a known different tab never matches"
    )
}

func testCLIParsesDoctorCommand() throws {
    try expect(try CLICommand.parse(arguments: ["doctor"]), equals: .doctor, "CLI command")
}

func testHookInputRejectsOversizedPayloads() throws {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(repeating: 0x61, count: BoundedInput.maximumPayloadSize + 1).write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }

    do {
        _ = try BoundedInput.read(from: handle)
        throw TestFailure.expectation("oversized hook input was accepted")
    } catch let error as InputError {
        try expect(error, equals: .payloadTooLarge, "hook input error")
    }
}

func testCodexNotifyMarksTurnComplete() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(directoryURL: directory)
    try repository.save(AgentSession.decode(
        from: validStateJSON(
            sessionID: "codex-1",
            status: "working",
            pid: Int32(getpid()),
            tool: "codex"
        )
    ))
    let payload = Data(
        #"{"type":"agent-turn-complete","thread-id":"codex-1","cwd":"/tmp/project"}"#.utf8
    )

    try CodexNotifyProcessor(repository: repository).process(
        payload: payload,
        processID: Int32(getpid()),
        now: Date(timeIntervalSince1970: 300)
    )

    let session = try repository.loadSessions().first.unwrap(or: "Codex state was not saved")
    try expect(session.status, equals: .idle, "notify status")
    try expect(session.attentionReason, equals: .turnComplete, "notify reason")
}

extension Data {
    func writeAtomically(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try write(to: url, options: .atomic)
    }
}

let tests: [(String, () throws -> Void)] = [
    ("version 1 state document reconstructs session", testVersionOneStateDocumentReconstructsSession),
    ("convoy session decodes current step", testConvoySessionDecodesCurrentStep),
    ("unsupported schema version is rejected", testUnsupportedSchemaVersionIsRejected),
    ("state repository reconstructs sessions from disk", testStateRepositoryReconstructsSessionsFromDisk),
    ("missing state directory loads as empty", testMissingStateDirectoryLoadsAsEmpty),
    ("malformed state does not hide valid sessions", testMalformedStateDoesNotHideValidSessions),
    ("saving session publishes canonical state file", testSavingSessionPublishesCanonicalStateFile),
    ("state files are private and session names do not collide", testStateFilesArePrivateAndSessionNamesDoNotCollide),
    ("state repository ignores symbolic links", testStateRepositoryIgnoresSymbolicLinks),
    ("Claude session start creates idle state", testClaudeSessionStartCreatesIdleState),
    ("Claude session start preserves existing status", testClaudeSessionStartPreservesExistingStatus),
    ("session duration formatter renders compact durations", testSessionDurationFormatterRendersCompactDurations),
    ("Claude permission notification requests attention", testClaudePermissionNotificationRequestsAttention),
    ("Claude lifecycle events produce expected states", testClaudeLifecycleEventsProduceExpectedStates),
    ("reaper deletes state for dead process", testReaperDeletesStateForDeadProcess),
    ("reaper creates fallback state for untracked process", testReaperCreatesFallbackStateForUntrackedProcess),
    ("reaper reaps against provided scan", testReaperReapsAgainstProvidedScan),
    ("reaper rebinds daemon-hosted session to visible process", testReaperRebindsDaemonHostedSessionToVisibleProcess),
    ("reaper prunes superseded sessions for same process", testReaperPrunesSupersededSessionsForSameProcess),
    ("reaper prefers native session over newer fallback", testReaperPrefersNativeSessionOverNewerFallback),
    ("observation scheduler tick persists fallback state", testObservationSchedulerTickPersistsFallbackState),
    ("observation scheduler publishes convoy run on tick", testObservationSchedulerPublishesConvoyRunOnTick),
    ("observation scheduler reaps immediately when process exits", testObservationSchedulerReapsImmediatelyWhenProcessExits),
    ("observation scheduler coalesces tick bursts", testObservationSchedulerCoalescesTickBursts),
    ("native state replaces reaper fallback for same process", testNativeStateReplacesReaperFallbackForSameProcess),
    ("debug renderer shows tool counts and session state", testDebugRendererShowsToolCountsAndSessionState),
    ("CLI parses debug command", testCLIParsesDebugCommand),
    ("CLI parses Claude hook command", testCLIParsesClaudeHookCommand),
    ("CLI parses Codex notify command", testCLIParsesCodexNotifyCommand),
    ("capture context emits terminal JSON", testCaptureContextEmitsTerminalJSON),
    ("Claude hook wrapper forwards payload and event", testClaudeHookWrapperForwardsPayloadAndEvent),
    ("state store reload filters ended sessions without writing", testStateStoreReloadFiltersEndedSessionsWithoutWriting),
    ("state store polling observes new state files", testStateStorePollingObservesNewStateFiles),
    ("state store file events observe new state files without polling", testStateStoreFileEventsObserveNewStateFilesWithoutPolling),
    ("state store Darwin notification observes new state files", testStateStoreDarwinNotificationObservesNewStateFiles),
    ("tool summary counts sessions and attention", testToolSummaryCountsSessionsAndAttention),
    ("tool summary reports worst status for semaphore", testToolSummaryReportsWorstStatusForSemaphore),
    ("notch wing placement splits tools around notch", testNotchWingPlacementSplitsToolsAroundNotch),
    ("attention acknowledgments silence visited sessions", testAttentionAcknowledgmentsSilenceVisitedSessionsUntilNewActivity),
    ("git workspace inspector resolves branch names", testGitWorkspaceInspectorResolvesBranchNames),
    ("notch layout extends from left side of hardware notch", testNotchLayoutExtendsFromLeftSideOfHardwareNotch),
    ("opencode plugin writes session state", testOpenCodePluginWritesSessionState),
    ("opencode plugin maps lifecycle events", testOpenCodePluginMapsLifecycleEvents),
    ("pi extension writes session state", testPiExtensionWritesSessionState),
    ("pi extension maps lifecycle events", testPiExtensionMapsLifecycleEvents),
    ("Codex rollout parser maps session and turn events", testCodexRolloutParserMapsSessionAndTurnEvents),
    ("Codex rollout parser ignores malformed and unknown lines", testCodexRolloutParserIgnoresMalformedAndUnknownLines),
    ("Codex sessions watcher processes appended lines incrementally", testCodexSessionsWatcherProcessesAppendedLinesIncrementally),
    ("Codex sessions watcher resaves when process appears later", testCodexSessionsWatcherResavesWhenProcessAppearsLater),
    ("Codex sessions watcher skips date directories outside window", testCodexSessionsWatcherSkipsDateDirectoriesOutsideWindow),
    ("convoy watcher publishes running pipeline step", testConvoyWatcherPublishesRunningPipelineStep),
    ("convoy watcher flags waiting human gate", testConvoyWatcherFlagsWaitingHumanGate),
    ("convoy watcher maps terminal pipeline states", testConvoyWatcherMapsTerminalPipelineStates),
    ("convoy watcher ignores runs not owned by live process", testConvoyWatcherIgnoresRunsNotOwnedByLiveProcess),
    ("convoy watcher suppresses pipeline-owned opencode sessions", testConvoyWatcherSuppressesPipelineOwnedOpenCodeSessions),
    ("focus planner prioritizes tmux then terminal", testFocusPlannerPrioritizesTmuxThenTerminal),
    ("Ghostty matcher excludes orphaned processes and assigns exact terminals", testGhosttyMatcherExcludesOrphanedProcessesAndAssignsExactTerminals),
    ("Ghostty matcher prefers same-directory terminal naming the tool", testGhosttyMatcherPrefersSameDirectoryTerminalNamingTheTool),
    ("Ghostty terminal query cache avoids redundant queries", testGhosttyTerminalQueryCacheAvoidsRedundantQueries),
    ("process scanner detects spawned agent process within budget", testProcessScannerDetectsSpawnedAgentProcessWithinBudget),
    ("process scanner ignores lookalike process names", testProcessScannerIgnoresLookalikeProcessNames),
    ("process scanner detects script runtime agents", testProcessScannerDetectsScriptRuntimeAgents),
    ("process scanner collapses runtime launcher onto native child", testProcessScannerCollapsesRuntimeLauncherOntoNativeChild),
    ("process scanner resolves parent of root-owned processes", testProcessScannerResolvesParentOfRootOwnedProcesses),
    ("process scanner identifies host terminal from ancestors", testProcessScannerIdentifiesHostTerminalFromAncestors),
    ("Claude settings merge preserves hooks and is idempotent", testClaudeSettingsMergePreservesHooksAndIsIdempotent),
    ("Claude settings removal preserves user hooks", testClaudeSettingsRemovalPreservesUserHooks),
    ("Claude settings quotes hook paths for the shell", testClaudeSettingsQuotesHookPathsForTheShell),
    ("installer rejects symlinked private directory", testInstallerRejectsSymlinkedPrivateDirectory),
    ("installer follows user-owned symlinked integration directories", testInstallerFollowsUserOwnedSymlinkedIntegrationDirectories),
    ("installer replaces marked integration files on reinstall", testInstallerReplacesMarkedIntegrationFilesOnReinstall),
    ("installer prepends codex notify before existing content", testInstallerPrependsCodexNotifyBeforeExistingContent),
    ("installation doctor reports healthy install", testInstallationDoctorReportsHealthyInstall),
    ("installation doctor pinpoints broken pieces", testInstallationDoctorPinpointsBrokenPieces),
    ("CLI parses doctor command", testCLIParsesDoctorCommand),
    ("front terminal matcher matches by ID and falls back to cwd", testFrontTerminalMatcherMatchesByIDAndFallsBackToWorkingDirectory),
    ("hook input rejects oversized payloads", testHookInputRejectsOversizedPayloads),
    ("Codex notify marks turn complete", testCodexNotifyMarksTurnComplete),
]

do {
    for (name, test) in tests {
        try test()
        print("PASS: \(name)")
    }
} catch {
    FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
    exit(1)
}

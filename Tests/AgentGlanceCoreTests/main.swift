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

func testClaudeSessionStartCreatesWorkingState() throws {
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
    try expect(session.status, equals: .working, "session status")
    try expect(session.startedAt, equals: now, "started at")
    try expect(session.terminal.termProgram, equals: "ghostty", "terminal program")
    try expect(session.terminal.tmuxPane, equals: "%7", "tmux pane")
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

func testStateStoreReloadsActiveSessionsAndRemovesEndedSessions() throws {
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
    try expect(try repository.loadSessions().map(\.sessionID), equals: ["active"], "ended state file")
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

func testNotchLayoutExtendsFromLeftSideOfHardwareNotch() throws {
    let layout = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 38,
        leftNotchEdgeX: 666,
        rightNotchEdgeX: 846
    )

    try expect(layout.width, equals: 362, "maximum panel width")
    try expect(layout.height, equals: 38, "panel height")
    try expect(layout.originX, equals: 484, "panel x")
    try expect(layout.originY, equals: 944, "panel y")
    try expect(layout.contentTopPadding, equals: 7, "content top padding")
    try expect(layout.contentWidth, equals: 182, "maximum left wing width")
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
    let stateFile = stateDirectory.appendingPathComponent(stateFiles.first ?? "missing")
    let directReadDiagnostic: String
    do {
        _ = try AgentSession.decode(from: Data(contentsOf: stateFile))
        let attributes = try FileManager.default.attributesOfItem(atPath: stateFile.path)
        directReadDiagnostic = "direct decode passed; attributes: \(attributes)"
    } catch {
        directReadDiagnostic = "direct decode failed: \(error)"
    }
    let session = try StateRepository(directoryURL: stateDirectory)
        .loadSessions().first.unwrap(
            or: "opencode state was not saved; files: \(stateFiles); \(directReadDiagnostic)"
        )
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

func detectedProcess(id: Int32, cwd: String, elapsed: TimeInterval) -> DetectedAgentProcess {
    DetectedAgentProcess(
        tool: .opencode,
        processID: id,
        cwd: cwd,
        terminal: TerminalContext(termProgram: "ghostty", tty: "/dev/ttys\(id)"),
        elapsedSeconds: elapsed
    )
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
    ("unsupported schema version is rejected", testUnsupportedSchemaVersionIsRejected),
    ("state repository reconstructs sessions from disk", testStateRepositoryReconstructsSessionsFromDisk),
    ("missing state directory loads as empty", testMissingStateDirectoryLoadsAsEmpty),
    ("malformed state does not hide valid sessions", testMalformedStateDoesNotHideValidSessions),
    ("saving session publishes canonical state file", testSavingSessionPublishesCanonicalStateFile),
    ("state files are private and session names do not collide", testStateFilesArePrivateAndSessionNamesDoNotCollide),
    ("state repository ignores symbolic links", testStateRepositoryIgnoresSymbolicLinks),
    ("Claude session start creates working state", testClaudeSessionStartCreatesWorkingState),
    ("Claude permission notification requests attention", testClaudePermissionNotificationRequestsAttention),
    ("Claude lifecycle events produce expected states", testClaudeLifecycleEventsProduceExpectedStates),
    ("reaper deletes state for dead process", testReaperDeletesStateForDeadProcess),
    ("reaper creates fallback state for untracked process", testReaperCreatesFallbackStateForUntrackedProcess),
    ("native state replaces reaper fallback for same process", testNativeStateReplacesReaperFallbackForSameProcess),
    ("debug renderer shows tool counts and session state", testDebugRendererShowsToolCountsAndSessionState),
    ("CLI parses debug command", testCLIParsesDebugCommand),
    ("CLI parses Claude hook command", testCLIParsesClaudeHookCommand),
    ("CLI parses Codex notify command", testCLIParsesCodexNotifyCommand),
    ("capture context emits terminal JSON", testCaptureContextEmitsTerminalJSON),
    ("Claude hook wrapper forwards payload and event", testClaudeHookWrapperForwardsPayloadAndEvent),
    ("state store reloads active sessions and removes ended sessions", testStateStoreReloadsActiveSessionsAndRemovesEndedSessions),
    ("state store polling observes new state files", testStateStorePollingObservesNewStateFiles),
    ("state store file events observe new state files without polling", testStateStoreFileEventsObserveNewStateFilesWithoutPolling),
    ("state store Darwin notification observes new state files", testStateStoreDarwinNotificationObservesNewStateFiles),
    ("tool summary counts sessions and attention", testToolSummaryCountsSessionsAndAttention),
    ("notch layout extends from left side of hardware notch", testNotchLayoutExtendsFromLeftSideOfHardwareNotch),
    ("opencode plugin writes session state", testOpenCodePluginWritesSessionState),
    ("opencode plugin maps lifecycle events", testOpenCodePluginMapsLifecycleEvents),
    ("Codex rollout parser maps session and turn events", testCodexRolloutParserMapsSessionAndTurnEvents),
    ("Codex rollout parser ignores malformed and unknown lines", testCodexRolloutParserIgnoresMalformedAndUnknownLines),
    ("Codex sessions watcher processes appended lines incrementally", testCodexSessionsWatcherProcessesAppendedLinesIncrementally),
    ("focus planner prioritizes tmux then terminal", testFocusPlannerPrioritizesTmuxThenTerminal),
    ("Ghostty matcher excludes orphaned processes and assigns exact terminals", testGhosttyMatcherExcludesOrphanedProcessesAndAssignsExactTerminals),
    ("Claude settings merge preserves hooks and is idempotent", testClaudeSettingsMergePreservesHooksAndIsIdempotent),
    ("Claude settings removal preserves user hooks", testClaudeSettingsRemovalPreservesUserHooks),
    ("Claude settings quotes hook paths for the shell", testClaudeSettingsQuotesHookPathsForTheShell),
    ("installer rejects symlinked private directory", testInstallerRejectsSymlinkedPrivateDirectory),
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

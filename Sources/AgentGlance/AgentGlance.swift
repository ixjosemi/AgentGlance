import Foundation

import AgentGlanceCore

let arguments = Array(CommandLine.arguments.dropFirst())
let isHookInvocation = arguments.first == "hook"

do {
    let command = try CLICommand.parse(arguments: arguments)
    let environment = ProcessInfo.processInfo.environment
    let homeDirectory = environment["AGENTGLANCE_HOME"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        ".agentglance",
        isDirectory: true
    )
    let repository = StateRepository(
        directoryURL: homeDirectory.appendingPathComponent("state", isDirectory: true)
    )

    switch command {
    case .debug:
        _ = try ReaperService(repository: repository).reap()
        print(DebugRenderer.render(sessions: try repository.loadSessions()))
    case .install:
        try Installer(
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            executableURL: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        ).install()
        print("AgentGlance hooks installed.")
    case .uninstall:
        try Installer(
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            executableURL: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        ).uninstall()
        print("AgentGlance files removed.")
    case .doctor:
        let checks = InstallationDoctor(
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        ).diagnose()
        for check in checks {
            print("\(check.passed ? "✓" : "✗") \(check.title): \(check.detail)")
        }
        if checks.contains(where: { !$0.passed }) {
            exit(1)
        }
    case let .claudeHook(event, processID):
        let payload = try BoundedInput.read(from: .standardInput)
        try ClaudeHookProcessor(repository: repository).process(
            event: event,
            payload: payload,
            environment: environment,
            processID: processID
        )
    case let .codexNotify(processID):
        try CodexNotifyProcessor(repository: repository).process(
            payload: try BoundedInput.read(from: .standardInput),
            processID: processID
        )
    }
} catch {
    if !isHookInvocation {
        FileHandle.standardError.write(Data("agentglance: \(error)\n".utf8))
        exit(1)
    }
}

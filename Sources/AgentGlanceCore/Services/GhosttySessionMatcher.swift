import Foundation

public struct GhosttyTerminal: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let cwd: String

    public init(id: String, name: String, cwd: String) {
        self.id = id
        self.name = name
        self.cwd = cwd
    }
}

public enum GhosttySessionMatcher {
    public static func match(
        processes: [DetectedAgentProcess],
        terminals: [GhosttyTerminal]
    ) -> [DetectedAgentProcess] {
        var availableTerminals = terminals
        var unmatchedProcesses: [DetectedAgentProcess] = []
        var matchedProcesses: [DetectedAgentProcess] = []

        for process in processes {
            guard let index = bestTerminalIndex(for: process, in: availableTerminals) else {
                unmatchedProcesses.append(process)
                continue
            }
            matchedProcesses.append(enrich(process, with: availableTerminals.remove(at: index)))
        }

        let blankTerminals = availableTerminals.filter { $0.cwd.isEmpty }
        let newestUnmatched = unmatchedProcesses.sorted { $0.elapsedSeconds < $1.elapsedSeconds }
        for (process, terminal) in zip(newestUnmatched, blankTerminals) {
            matchedProcesses.append(enrich(process, with: terminal))
        }
        return matchedProcesses
    }

    private static func bestTerminalIndex(
        for process: DetectedAgentProcess,
        in terminals: [GhosttyTerminal]
    ) -> Int? {
        if let exact = terminals.firstIndex(where: { !$0.cwd.isEmpty && $0.cwd == process.cwd }) {
            return exact
        }
        let projectName = URL(fileURLWithPath: process.cwd).lastPathComponent.lowercased()
        guard projectName.count >= 8, projectName != "development" else { return nil }
        return terminals.firstIndex { $0.name.lowercased().contains(projectName) }
    }

    private static func enrich(
        _ process: DetectedAgentProcess,
        with terminal: GhosttyTerminal
    ) -> DetectedAgentProcess {
        DetectedAgentProcess(
            tool: process.tool,
            processID: process.processID,
            cwd: process.cwd,
            terminal: TerminalContext(
                termProgram: "ghostty",
                ghosttyTerminalID: terminal.id,
                tmuxPane: process.terminal.tmuxPane,
                tty: process.terminal.tty,
                windowTitleHint: terminal.name
            ),
            elapsedSeconds: process.elapsedSeconds
        )
    }
}

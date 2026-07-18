import Foundation

public struct DetectedAgentProcess: Equatable, Sendable {
    public let tool: AgentTool
    public let processID: Int32
    public let cwd: String
    public let terminal: TerminalContext
    public let elapsedSeconds: TimeInterval

    public init(
        tool: AgentTool,
        processID: Int32,
        cwd: String,
        terminal: TerminalContext,
        elapsedSeconds: TimeInterval = .greatestFiniteMagnitude
    ) {
        self.tool = tool
        self.processID = processID
        self.cwd = cwd
        self.terminal = terminal
        self.elapsedSeconds = elapsedSeconds
    }
}

public protocol ProcessScanning: Sendable {
    func activeProcesses() throws -> [DetectedAgentProcess]
}

public struct SystemProcessScanner: ProcessScanning {
    public init() {}

    public func activeProcesses() throws -> [DetectedAgentProcess] {
        var detected: [DetectedAgentProcess] = []
        for tool in AgentTool.allCases {
            for processID in try processIDs(named: tool.rawValue) {
                guard let cwd = try workingDirectory(processID: processID) else { continue }
                let tty = try terminalTTY(processID: processID)
                let termProgram = try terminalProgram(processID: processID)
                detected.append(DetectedAgentProcess(
                    tool: tool,
                    processID: processID,
                    cwd: cwd,
                    terminal: TerminalContext(termProgram: termProgram, tty: tty),
                    elapsedSeconds: try elapsedSeconds(processID: processID)
                ))
            }
        }
        let ghosttyProcesses = detected.filter { $0.terminal.termProgram == "ghostty" }
        guard !ghosttyProcesses.isEmpty,
              let terminals = try? ghosttyTerminals() else {
            return detected
        }
        let nonGhosttyProcesses = detected.filter { $0.terminal.termProgram != "ghostty" }
        let matched = GhosttySessionMatcher.match(
            processes: ghosttyProcesses,
            terminals: terminals
        )
        return nonGhosttyProcesses + matched
    }

    private func processIDs(named name: String) throws -> [Int32] {
        let exact = try run("/usr/bin/pgrep", arguments: ["-x", name])
        let pathBased = try run("/usr/bin/pgrep", arguments: ["-f", "/\(name)"])
        let candidates = Set(
            (exact.output + "\n" + pathBased.output)
                .split(whereSeparator: \.isNewline)
                .compactMap { Int32($0) }
        )
        return try candidates.filter { processID in
            let command = try run(
                "/bin/ps",
                arguments: ["-o", "comm=", "-p", String(processID)]
            ).output.trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(fileURLWithPath: command).lastPathComponent == name
        }
    }

    private func workingDirectory(processID: Int32) throws -> String? {
        let result = try run(
            "/usr/sbin/lsof",
            arguments: ["-a", "-p", String(processID), "-d", "cwd", "-Fn"]
        )
        return result.output.split(whereSeparator: \.isNewline)
            .first(where: { $0.first == "n" })
            .map { String($0.dropFirst()) }
    }

    private func terminalTTY(processID: Int32) throws -> String? {
        let result = try run("/bin/ps", arguments: ["-o", "tty=", "-p", String(processID)])
        let tty = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tty.isEmpty, tty != "??" else { return nil }
        return tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
    }

    private func terminalProgram(processID: Int32) throws -> String? {
        var currentProcessID = processID
        for _ in 0..<8 {
            let result = try run(
                "/bin/ps",
                arguments: ["-o", "ppid=,command=", "-p", String(currentProcessID)]
            )
            let fields = result.output
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, let parentProcessID = Int32(fields[0]) else { return nil }
            let command = String(fields[1])
            if command.contains("/Ghostty.app/") { return "ghostty" }
            if command.contains("/iTerm.app/") { return "iTerm.app" }
            if command.contains("/Terminal.app/") { return "Apple_Terminal" }
            guard parentProcessID > 1 else { return nil }
            currentProcessID = parentProcessID
        }
        return nil
    }

    private func elapsedSeconds(processID: Int32) throws -> TimeInterval {
        let result = try run("/bin/ps", arguments: ["-o", "etime=", "-p", String(processID)])
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let dayParts = value.split(separator: "-", maxSplits: 1).map(String.init)
        let days = dayParts.count == 2 ? (Double(dayParts[0]) ?? 0) : 0
        let time = dayParts.last?.split(separator: ":").compactMap { Double($0) } ?? []
        let seconds = time.reversed().enumerated().reduce(0.0) { total, component in
            total + component.element * pow(60, Double(component.offset))
        }
        return days * 86_400 + seconds
    }

    private func ghosttyTerminals() throws -> [GhosttyTerminal] {
        let script = """
        const app = Application("Ghostty");
        JSON.stringify(app.terminals().map(t => ({
          id: t.id(), name: t.name(), cwd: t.workingDirectory()
        })))
        """
        let result = try run("/usr/bin/osascript", arguments: ["-l", "JavaScript", "-e", script])
        guard result.status == 0, let data = result.output.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode([GhosttyTerminal].self, from: data)
    }

    private func run(_ executable: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

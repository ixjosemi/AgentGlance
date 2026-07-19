import Foundation
import Darwin

public enum FocusAction: Equatable, Sendable {
    case run(executable: String, arguments: [String])
    case appleScript(String)
}

public enum FocusError: Error, Equatable, Sendable {
    case invalidTmuxPane(String)
    case commandFailed(String, Int32)
}

public enum FocusPlanner {
    public static func actions(for session: AgentSession) throws -> [FocusAction] {
        var actions: [FocusAction] = []
        if let pane = session.terminal.tmuxPane {
            guard pane.range(of: #"^%[0-9]+$"#, options: .regularExpression) != nil else {
                throw FocusError.invalidTmuxPane(pane)
            }
            actions.append(.run(executable: "tmux", arguments: ["select-window", "-t", pane]))
            actions.append(.run(executable: "tmux", arguments: ["select-pane", "-t", pane]))
        }
        actions.append(terminalAction(for: session))
        return actions
    }

    private static func terminalAction(for session: AgentSession) -> FocusAction {
        if session.terminal.termProgram?.lowercased() == "ghostty" {
            return .appleScript(ghosttyScript(for: session))
        }
        if let identifier = session.terminal.itermSessionID {
            return .appleScript(iTermScript(identifier: identifier))
        }
        if let tty = session.terminal.tty,
           session.terminal.termProgram == "Apple_Terminal" {
            return .appleScript(terminalScript(tty: tty))
        }
        let application = applicationName(for: session.terminal.termProgram)
        return .run(executable: "/usr/bin/open", arguments: ["-a", application])
    }

    private static func ghosttyScript(for session: AgentSession) -> String {
        let cwd = appleScriptString(session.cwd)
        let hint = appleScriptString(session.terminal.windowTitleHint ?? session.projectName)
        let identifier = session.terminal.ghosttyTerminalID.map(appleScriptString)
        let initialMatch = identifier.map {
            "set matches to every terminal whose id is \"\($0)\""
        } ?? "set matches to every terminal whose working directory contains \"\(cwd)\""
        return """
        tell application "Ghostty"
          \(initialMatch)
          if (count of matches) = 0 then set matches to every terminal whose working directory contains "\(cwd)"
          if (count of matches) is not 1 then set matches to every terminal whose name contains "\(hint)"
          if (count of matches) > 0 then focus item 1 of matches
          activate
        end tell
        """
    }

    private static func iTermScript(identifier: String) -> String {
        let value = appleScriptString(identifier)
        return """
        tell application "iTerm2"
          repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
              repeat with aSession in sessions of aTab
                if unique ID of aSession contains "\(value)" then select aTab
              end repeat
            end repeat
          end repeat
          activate
        end tell
        """
    }

    private static func terminalScript(tty: String) -> String {
        let value = appleScriptString(tty.replacingOccurrences(of: "/dev/", with: ""))
        return """
        tell application "Terminal"
          repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
              if tty of aTab contains "\(value)" then set selected tab of aWindow to aTab
            end repeat
          end repeat
          activate
        end tell
        """
    }

    private static func applicationName(for termProgram: String?) -> String {
        switch termProgram {
        case "Apple_Terminal": "Terminal"
        case "iTerm.app": "iTerm"
        case "ghostty": "Ghostty"
        default: "Terminal"
        }
    }

    static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

public enum FocusService {
    public static func focus(_ session: AgentSession) throws {
        try FocusActionRunner.run(FocusPlanner.actions(for: session))
    }
}

/// Executes planned terminal actions — subprocess or AppleScript — for both
/// focusing and terminating sessions. Every action runs even after an
/// earlier one fails, so a dead tmux binding never blocks the terminal
/// action behind it; the first failure is still reported.
enum FocusActionRunner {
    static func run(_ actions: [FocusAction]) throws {
        var firstError: Error?
        for action in actions {
            let process = Process()
            switch action {
            case let .run(executable, arguments):
                process.executableURL = try executableURL(named: executable)
                process.arguments = arguments
            case let .appleScript(script):
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
            }
            do {
                try process.run()
            } catch {
                if firstError == nil { firstError = error }
                continue
            }
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                if firstError == nil {
                    firstError = FocusError.commandFailed(
                        process.executableURL?.path ?? "command",
                        process.terminationStatus
                    )
                }
            }
        }
        if let firstError { throw firstError }
    }

    private static func executableURL(named executable: String) throws -> URL {
        if executable.hasPrefix("/") {
            return URL(fileURLWithPath: executable)
        }
        let trustedDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for directory in trustedDirectories {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent(executable)
                .resolvingSymlinksInPath()
            var metadata = stat()
            guard Darwin.lstat(candidate.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_mode & 0o022 == 0,
                  metadata.st_uid == 0 || metadata.st_uid == getuid(),
                  FileManager.default.isExecutableFile(atPath: candidate.path) else {
                continue
            }
            return candidate
        }
        throw CocoaError(.fileNoSuchFile)
    }
}

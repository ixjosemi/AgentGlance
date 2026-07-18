import Foundation

public enum InstallationError: Error, Equatable, Sendable {
    case invalidClaudeSettings
    case unsafeInstallationPath(String)
    case existingIntegrationFile(String)
}

public enum ClaudeSettingsMerger {
    public static func merge(settingsData: Data, hookCommand: String) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: settingsData) as? [String: Any] else {
            throw InstallationError.invalidClaudeSettings
        }
        var allHooks = root["hooks"] as? [String: Any] ?? [:]
        let events: [(name: String, matcher: String?)] = [
            ("SessionStart", nil),
            ("Notification", "permission_prompt|idle_prompt"),
            ("UserPromptSubmit", nil),
            ("Stop", nil),
            ("SessionEnd", nil),
        ]
        for event in events {
            var groups = allHooks[event.name] as? [[String: Any]] ?? []
            let command = command(hookCommand: hookCommand, eventName: event.name)
            if !contains(command: command, in: groups) {
                groups.append(group(command: command, matcher: event.matcher))
            }
            allHooks[event.name] = groups
        }
        root["hooks"] = allHooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    public static func remove(settingsData: Data, hookCommand: String) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: settingsData) as? [String: Any] else {
            throw InstallationError.invalidClaudeSettings
        }
        var allHooks = root["hooks"] as? [String: Any] ?? [:]
        for eventName in ["SessionStart", "Notification", "UserPromptSubmit", "Stop", "SessionEnd"] {
            let command = command(hookCommand: hookCommand, eventName: eventName)
            let groups = allHooks[eventName] as? [[String: Any]] ?? []
            allHooks[eventName] = groups.filter { !contains(command: command, in: [$0]) }
        }
        root["hooks"] = allHooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static func contains(command: String, in groups: [[String: Any]]) -> Bool {
        groups.contains { group in
            let hooks = group["hooks"] as? [[String: Any]] ?? []
            return hooks.contains { $0["command"] as? String == command }
        }
    }

    private static func group(command: String, matcher: String?) -> [String: Any] {
        var group: [String: Any] = [
            "hooks": [["type": "command", "command": command]],
        ]
        if let matcher {
            group["matcher"] = matcher
        }
        return group
    }

    private static func command(hookCommand: String, eventName: String) -> String {
        "\(shellQuote(hookCommand)) \(shellQuote(eventName))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

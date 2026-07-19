import Foundation
import Darwin

public struct DoctorCheck: Equatable, Sendable {
    public let title: String
    public let passed: Bool
    public let detail: String

    public init(title: String, passed: Bool, detail: String) {
        self.title = title
        self.passed = passed
        self.detail = detail
    }
}

/// Read-only diagnosis of an AgentGlance installation. Every check inspects
/// the same files the Installer writes — binaries, Claude hooks, OpenCode
/// plugin, Codex notify — without mutating anything, so it is safe to run
/// at any time.
public struct InstallationDoctor {
    private static let hookBinaryNames = [
        "agentglance",
        "claude-hook.sh",
        "codex-notify.sh",
        "capture-context.sh",
    ]

    private let homeDirectoryURL: URL

    public init(homeDirectoryURL: URL) {
        self.homeDirectoryURL = homeDirectoryURL
    }

    public func diagnose() -> [DoctorCheck] {
        [
            hookBinariesCheck(),
            stateDirectoryCheck(),
            claudeHooksCheck(),
            openCodePluginCheck(),
            codexNotifyCheck(),
        ]
    }

    private var binDirectory: URL {
        homeDirectoryURL.appendingPathComponent(".agentglance/bin")
    }

    private func hookBinariesCheck() -> DoctorCheck {
        let missing = Self.hookBinaryNames.filter { name in
            Darwin.access(binDirectory.appendingPathComponent(name).path, X_OK) != 0
        }
        return DoctorCheck(
            title: "hook binaries",
            passed: missing.isEmpty,
            detail: missing.isEmpty
                ? "all executables present in \(display(binDirectory))"
                : "missing or not executable: \(missing.joined(separator: ", "))"
        )
    }

    private func stateDirectoryCheck() -> DoctorCheck {
        let stateDirectory = homeDirectoryURL.appendingPathComponent(".agentglance/state")
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: stateDirectory.path,
            isDirectory: &isDirectory
        )
        return DoctorCheck(
            title: "state directory",
            passed: exists && isDirectory.boolValue,
            detail: exists && isDirectory.boolValue
                ? "\(display(stateDirectory)) exists"
                : "\(display(stateDirectory)) is missing — run: agentglance install"
        )
    }

    private func claudeHooksCheck() -> DoctorCheck {
        let settingsURL = homeDirectoryURL.appendingPathComponent(".claude/settings.json")
        guard let settingsData = try? Data(contentsOf: settingsURL) else {
            return DoctorCheck(
                title: "Claude Code hooks",
                passed: false,
                detail: "\(display(settingsURL)) is missing — run: agentglance install"
            )
        }
        let installed = ClaudeSettingsMerger.isInstalled(
            settingsData: settingsData,
            hookCommand: binDirectory.appendingPathComponent("claude-hook.sh").path
        )
        return DoctorCheck(
            title: "Claude Code hooks",
            passed: installed,
            detail: installed
                ? "all lifecycle hooks registered in \(display(settingsURL))"
                : "hooks missing from \(display(settingsURL)) — run: agentglance install"
        )
    }

    private func openCodePluginCheck() -> DoctorCheck {
        let plugin = homeDirectoryURL.appendingPathComponent(
            ".config/opencode/plugins/agentglance.js"
        )
        guard let installedPlugin = try? Data(contentsOf: plugin) else {
            return DoctorCheck(
                title: "OpenCode plugin",
                passed: false,
                detail: "\(display(plugin)) is missing — run: agentglance install"
            )
        }
        let matchesBundled = (try? Data(contentsOf: BundledResources.opencodePluginURL))
            == installedPlugin
        return DoctorCheck(
            title: "OpenCode plugin",
            passed: matchesBundled,
            detail: matchesBundled
                ? "\(display(plugin)) matches the bundled plugin"
                : "\(display(plugin)) differs from the bundled plugin — reinstall to update"
        )
    }

    private func codexNotifyCheck() -> DoctorCheck {
        let configURL = homeDirectoryURL.appendingPathComponent(".codex/config.toml")
        guard let config = try? String(contentsOf: configURL, encoding: .utf8) else {
            return DoctorCheck(
                title: "Codex notify",
                passed: false,
                detail: "\(display(configURL)) is missing — run: agentglance install"
            )
        }
        let configured = config.range(
            of: #"(?m)^\s*notify\s*=.*codex-notify\.sh"#,
            options: .regularExpression
        ) != nil
        return DoctorCheck(
            title: "Codex notify",
            passed: configured,
            detail: configured
                ? "notify hook registered in \(display(configURL))"
                : "notify hook missing from \(display(configURL)) — run: agentglance install"
        )
    }

    private func display(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let homePath = homeDirectoryURL.standardizedFileURL.path
        guard path.hasPrefix(homePath + "/") else { return path }
        return "~" + path.dropFirst(homePath.count)
    }
}

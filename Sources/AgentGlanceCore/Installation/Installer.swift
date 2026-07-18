import Foundation
import Darwin

public struct Installer {
    private let homeDirectoryURL: URL
    private let executableURL: URL

    public init(homeDirectoryURL: URL, executableURL: URL) {
        self.homeDirectoryURL = homeDirectoryURL
        self.executableURL = executableURL
    }

    public func install() throws {
        let agentGlanceDirectory = homeDirectoryURL.appendingPathComponent(".agentglance")
        let binaryDirectory = agentGlanceDirectory.appendingPathComponent("bin")
        try validateManagedDirectories([
            agentGlanceDirectory,
            homeDirectoryURL.appendingPathComponent(".claude"),
            homeDirectoryURL.appendingPathComponent(".config/opencode/plugins"),
            homeDirectoryURL.appendingPathComponent(".codex"),
        ])
        try preflightInstallation()
        try FileManager.default.createDirectory(
            at: agentGlanceDirectory.appendingPathComponent("state"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        for directory in [agentGlanceDirectory, binaryDirectory, agentGlanceDirectory.appendingPathComponent("state")] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        try copy(executableURL, to: binaryDirectory.appendingPathComponent("agentglance"), executable: true)
        try copy(BundledResources.claudeHookScriptURL, to: binaryDirectory.appendingPathComponent("claude-hook.sh"), executable: true)
        try copy(BundledResources.codexNotifyScriptURL, to: binaryDirectory.appendingPathComponent("codex-notify.sh"), executable: true)
        try copy(BundledResources.captureContextScriptURL, to: binaryDirectory.appendingPathComponent("capture-context.sh"), executable: true)
        try installClaudeSettings(hookDirectory: binaryDirectory)
        try installOpenCodePlugin()
        try installCodexNotify(hookDirectory: binaryDirectory)
    }

    public func uninstall() throws {
        let agentGlanceDirectory = homeDirectoryURL.appendingPathComponent(".agentglance")
        try validateManagedDirectories([
            agentGlanceDirectory,
            homeDirectoryURL.appendingPathComponent(".claude"),
            homeDirectoryURL.appendingPathComponent(".config/opencode/plugins"),
            homeDirectoryURL.appendingPathComponent(".codex"),
        ])
        try uninstallClaudeSettings(
            hookDirectory: agentGlanceDirectory.appendingPathComponent("bin")
        )
        try uninstallCodexNotify(
            hookDirectory: agentGlanceDirectory.appendingPathComponent("bin")
        )
        let plugin = homeDirectoryURL.appendingPathComponent(
            ".config/opencode/plugins/agentglance.js"
        )
        if FileManager.default.fileExists(atPath: plugin.path),
           try Data(contentsOf: plugin) == Data(contentsOf: BundledResources.opencodePluginURL) {
            try removeIfPresent(plugin)
        }
        try removeIfPresent(agentGlanceDirectory)
    }

    private func uninstallClaudeSettings(hookDirectory: URL) throws {
        let settingsURL = homeDirectoryURL.appendingPathComponent(".claude/settings.json")
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let updated = try ClaudeSettingsMerger.remove(
            settingsData: Data(contentsOf: settingsURL),
            hookCommand: hookDirectory.appendingPathComponent("claude-hook.sh").path
        )
        try updated.write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    }

    private func uninstallCodexNotify(hookDirectory: URL) throws {
        let configURL = homeDirectoryURL.appendingPathComponent(".codex/config.toml")
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        var config = try String(contentsOf: configURL, encoding: .utf8)
        let path = hookDirectory.appendingPathComponent("codex-notify.sh").path
        config = config.replacingOccurrences(
            of: "notify = [\"\(path)\"]\n",
            with: ""
        )
        try Data(config.utf8).write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    private func installClaudeSettings(hookDirectory: URL) throws {
        let directory = homeDirectoryURL.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settingsURL = directory.appendingPathComponent("settings.json")
        let existing = FileManager.default.fileExists(atPath: settingsURL.path)
            ? try Data(contentsOf: settingsURL)
            : Data("{}".utf8)
        let merged = try ClaudeSettingsMerger.merge(
            settingsData: existing,
            hookCommand: hookDirectory.appendingPathComponent("claude-hook.sh").path
        )
        try merged.write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    }

    private func installOpenCodePlugin() throws {
        let directory = homeDirectoryURL.appendingPathComponent(".config/opencode/plugins")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("agentglance.js")
        if FileManager.default.fileExists(atPath: destination.path),
           try Data(contentsOf: destination) != Data(contentsOf: BundledResources.opencodePluginURL) {
            throw InstallationError.existingIntegrationFile(destination.path)
        }
        try copy(
            BundledResources.opencodePluginURL,
            to: destination,
            executable: false
        )
    }

    private func installCodexNotify(hookDirectory: URL) throws {
        let directory = homeDirectoryURL.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("config.toml")
        var config = FileManager.default.fileExists(atPath: configURL.path)
            ? try String(contentsOf: configURL, encoding: .utf8)
            : ""
        if config.range(of: #"(?m)^\s*notify\s*="#, options: .regularExpression) == nil {
            let script = hookDirectory.appendingPathComponent("codex-notify.sh").path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let notificationLine = "notify = [\"\(script)\"]\n\n"
            if let firstTable = config.range(of: #"(?m)^\s*\["#, options: .regularExpression) {
                config.insert(contentsOf: notificationLine, at: firstTable.lowerBound)
            } else {
                config += "\n\(notificationLine)"
            }
            try Data(config.utf8).write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        }
    }

    private func copy(_ source: URL, to destination: URL, executable: Bool) throws {
        if source.standardizedFileURL.resolvingSymlinksInPath()
            == destination.standardizedFileURL.resolvingSymlinksInPath() {
            return
        }
        try removeIfPresent(destination)
        try FileManager.default.copyItem(at: source, to: destination)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func validateManagedDirectories(_ directories: [URL]) throws {
        let homePath = homeDirectoryURL.standardizedFileURL.path
        for directory in directories {
            let path = directory.standardizedFileURL.path
            guard path == homePath || path.hasPrefix(homePath + "/") else {
                throw InstallationError.unsafeInstallationPath(path)
            }
            var current = homeDirectoryURL.standardizedFileURL
            let relativeComponents = directory.standardizedFileURL.pathComponents
                .dropFirst(homeDirectoryURL.standardizedFileURL.pathComponents.count)
            for component in relativeComponents {
                current.appendPathComponent(component)
                var metadata = stat()
                if Darwin.lstat(current.path, &metadata) == 0 {
                    guard metadata.st_mode & S_IFMT == S_IFDIR else {
                        throw InstallationError.unsafeInstallationPath(current.path)
                    }
                } else if errno != ENOENT {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    private func preflightInstallation() throws {
        var executableMetadata = stat()
        guard Darwin.lstat(executableURL.path, &executableMetadata) == 0,
              executableMetadata.st_mode & S_IFMT == S_IFREG else {
            throw InstallationError.unsafeInstallationPath(executableURL.path)
        }

        let claudeSettings = homeDirectoryURL.appendingPathComponent(".claude/settings.json")
        if FileManager.default.fileExists(atPath: claudeSettings.path) {
            _ = try ClaudeSettingsMerger.merge(
                settingsData: Data(contentsOf: claudeSettings),
                hookCommand: homeDirectoryURL.appendingPathComponent(".agentglance/bin/claude-hook.sh").path
            )
        }

        let codexConfig = homeDirectoryURL.appendingPathComponent(".codex/config.toml")
        if FileManager.default.fileExists(atPath: codexConfig.path) {
            _ = try String(contentsOf: codexConfig, encoding: .utf8)
        }

        let plugin = homeDirectoryURL.appendingPathComponent(".config/opencode/plugins/agentglance.js")
        if FileManager.default.fileExists(atPath: plugin.path),
           try Data(contentsOf: plugin) != Data(contentsOf: BundledResources.opencodePluginURL) {
            throw InstallationError.existingIntegrationFile(plugin.path)
        }
    }
}

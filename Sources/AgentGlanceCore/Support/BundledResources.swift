import Foundation

public enum BundledResources {
    public static let captureContextScriptURL = resourceURL(
        named: "capture-context",
        extension: "sh",
        subdirectory: "Resources/hooks"
    )
    public static let claudeHookScriptURL = resourceURL(
        named: "claude-hook",
        extension: "sh",
        subdirectory: "Resources/hooks"
    )
    public static let codexNotifyScriptURL = resourceURL(
        named: "codex-notify",
        extension: "sh",
        subdirectory: "Resources/hooks"
    )
    public static let opencodePluginURL = resourceURL(
        named: "agentglance",
        extension: "js",
        subdirectory: "Resources/opencode"
    )

    private static func resourceURL(
        named name: String,
        extension fileExtension: String,
        subdirectory: String
    ) -> URL {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ) else {
            fatalError("AgentGlance resource is missing: \(name).\(fileExtension)")
        }
        return url
    }
}

import Foundation

/// Splits the active tools across the hardware notch. The canonical order
/// reads left to right — Convoy, Pi, Codex, OpenCode, Claude — and the
/// wings share the tools evenly: the left wing takes the first ceil(N/2),
/// the right wing the rest. Two tools sit one per side, four sit two and
/// two, instead of piling everything but Claude on the left.
public struct NotchWingPlacement: Equatable, Sendable {
    public let leftWing: [ToolSummary]
    public let rightWing: [ToolSummary]

    private static let toolOrder: [AgentTool] = [.convoy, .pi, .codex, .opencode, .claude]

    public static func place(_ summaries: [ToolSummary]) -> NotchWingPlacement {
        let ordered = toolOrder.compactMap { tool in summaries.first { $0.tool == tool } }
        let splitIndex = (ordered.count + 1) / 2
        return NotchWingPlacement(
            leftWing: Array(ordered.prefix(splitIndex)),
            rightWing: Array(ordered.dropFirst(splitIndex))
        )
    }
}

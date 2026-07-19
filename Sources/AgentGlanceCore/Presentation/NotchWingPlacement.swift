import Foundation

/// Splits the active tools across the hardware notch: Convoy, Pi, Codex,
/// and OpenCode sit on the left wing (Convoy outermost), Claude sits alone
/// on the right wing.
public struct NotchWingPlacement: Equatable, Sendable {
    public let leftWing: [ToolSummary]
    public let rightWing: [ToolSummary]

    private static let leftWingOrder: [AgentTool] = [.convoy, .pi, .codex, .opencode]
    private static let rightWingOrder: [AgentTool] = [.claude]

    public static func place(_ summaries: [ToolSummary]) -> NotchWingPlacement {
        NotchWingPlacement(
            leftWing: ordered(summaries, by: leftWingOrder),
            rightWing: ordered(summaries, by: rightWingOrder)
        )
    }

    private static func ordered(
        _ summaries: [ToolSummary],
        by wingOrder: [AgentTool]
    ) -> [ToolSummary] {
        wingOrder.compactMap { tool in summaries.first { $0.tool == tool } }
    }
}

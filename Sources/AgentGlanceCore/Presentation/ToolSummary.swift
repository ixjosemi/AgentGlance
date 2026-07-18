import Foundation

public struct ToolSummary: Equatable, Sendable {
    public let tool: AgentTool
    public let sessionCount: Int
    public let needsAttention: Bool

    public init(tool: AgentTool, sessions: [AgentSession]) {
        let matchingSessions = sessions.filter { $0.tool == tool }
        self.tool = tool
        sessionCount = matchingSessions.count
        needsAttention = matchingSessions.contains { $0.status == .needsAttention }
    }

    public static func active(in sessions: [AgentSession]) -> [ToolSummary] {
        AgentTool.allCases
            .map { ToolSummary(tool: $0, sessions: sessions) }
            .filter { $0.sessionCount > 0 }
    }
}

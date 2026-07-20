import Foundation

public struct ToolSummary: Equatable, Sendable {
    public let tool: AgentTool
    public let sessionCount: Int
    public let needsAttention: Bool
    /// The most pressing status across this tool's sessions — chooses the
    /// bar indicator: needsAttention lights up red, working shows the pixel
    /// spinner, idle (the resting state) shows nothing at all.
    public let worstStatus: SessionStatus?

    private static let severityOrder: [SessionStatus] = [.needsAttention, .working, .idle]

    public init(tool: AgentTool, sessions: [AgentSession]) {
        let matchingSessions = sessions.filter { $0.tool == tool }
        self.tool = tool
        sessionCount = matchingSessions.count
        needsAttention = matchingSessions.contains { $0.status == .needsAttention }
        let statuses = Set(matchingSessions.map(\.status))
        worstStatus = Self.severityOrder.first { statuses.contains($0) }
    }

    public static func active(in sessions: [AgentSession]) -> [ToolSummary] {
        AgentTool.allCases
            .map { ToolSummary(tool: $0, sessions: sessions) }
            .filter { $0.sessionCount > 0 }
    }
}

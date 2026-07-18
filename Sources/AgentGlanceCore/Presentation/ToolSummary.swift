import Foundation

public struct ToolSummary: Equatable, Sendable {
    public let tool: AgentTool
    public let sessionCount: Int
    public let needsAttention: Bool
    /// The most pressing status across this tool's sessions — the color of
    /// its semaphore light: needsAttention > idle > working.
    public let worstStatus: SessionStatus?

    private static let severityOrder: [SessionStatus] = [.needsAttention, .idle, .working]

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

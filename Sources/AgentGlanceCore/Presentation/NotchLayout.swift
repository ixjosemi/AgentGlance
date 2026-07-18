import Foundation

public struct NotchLayout: Equatable, Sendable {
    public let width: CGFloat
    public let height: CGFloat
    public let originX: CGFloat
    public let originY: CGFloat
    public let contentTopPadding: CGFloat
    public let contentWidth: CGFloat
    public let notchWidth: CGFloat

    public init(
        screenMinX: CGFloat,
        screenWidth: CGFloat,
        screenMaxY: CGFloat,
        safeAreaTop: CGFloat,
        leftNotchEdgeX: CGFloat?,
        rightNotchEdgeX: CGFloat?
    ) {
        contentWidth = Self.wingWidth(activeToolCount: AgentTool.allCases.count)
        height = safeAreaTop > 0 ? safeAreaTop : 36
        contentTopPadding = max((height - 24) / 2, 0)
        let centerX = screenMinX + screenWidth / 2
        let leftEdge = leftNotchEdgeX ?? (centerX - 84)
        let rightEdge = rightNotchEdgeX ?? (centerX + 84)
        notchWidth = max(rightEdge - leftEdge, 168)
        width = contentWidth + notchWidth
        originX = leftEdge - contentWidth
        originY = screenMaxY - height
    }

    public static func wingWidth(activeToolCount: Int) -> CGFloat {
        let count = min(max(activeToolCount, 0), AgentTool.allCases.count)
        guard count > 0 else { return 30 }
        return CGFloat(count * 50 + (count - 1) * 6 + 20)
    }
}

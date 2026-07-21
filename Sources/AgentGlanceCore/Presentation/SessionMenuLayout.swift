import Foundation

/// Shared expanded-menu spacing. Keeping these values outside the SwiftUI
/// tree makes the deliberately roomier layout explicit and testable.
public enum SessionMenuLayout {
    public static let contentHorizontalInset: CGFloat = 18
    public static let headerTopPadding: CGFloat = 16
    public static let headerBottomPadding: CGFloat = 8
    public static let cardBottomPadding: CGFloat = 12
    public static let sessionRowHeight: CGFloat = 52
    public static let maximumSessionListHeight: CGFloat = 260
    public static let expandedActionsHeight: CGFloat = 144

    public static func sessionListHeight(
        sessionCount: Int,
        hasExpandedActions: Bool
    ) -> CGFloat {
        let count = max(0, sessionCount)
        let rowsHeight = CGFloat(count) * sessionRowHeight
        let actionsHeight = hasExpandedActions ? expandedActionsHeight : 0
        return min(rowsHeight + actionsHeight, maximumSessionListHeight)
    }
}

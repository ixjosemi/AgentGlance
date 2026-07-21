import Foundation

/// Shared expanded-menu spacing. Keeping these values outside the SwiftUI
/// tree makes the compact horizontal layout explicit and testable.
public enum SessionMenuLayout {
    public static let contentHorizontalInset: CGFloat = 8
    public static let headerTopPadding: CGFloat = 16
    public static let headerBottomPadding: CGFloat = 8
    public static let headerContentHeight: CGFloat = 22
    public static let cardStackSpacing: CGFloat = 2
    public static let cardBottomPadding: CGFloat = 12
    public static let sessionListBottomPadding: CGFloat = 8
    public static let sessionRowHeight: CGFloat = 52
    /// Three full rows plus the inline actions fit without shifting the row
    /// that received the click out from under the pointer. Longer lists still
    /// scroll inside the card.
    public static let maximumSessionListHeight: CGFloat = 300
    public static let expandedActionsHeight: CGFloat = 144

    /// The largest card the panel must accommodate: its header, a fitting
    /// three-row expanded list, and every vertical inset rendered by
    /// `SessionMenuCard`.
    public static let maximumCardHeight: CGFloat = headerTopPadding
        + headerContentHeight
        + headerBottomPadding
        + cardStackSpacing
        + maximumSessionListHeight
        + sessionListBottomPadding
        + cardBottomPadding

    public static func sessionListHeight(
        sessionCount: Int,
        hasExpandedActions: Bool
    ) -> CGFloat {
        let count = max(0, sessionCount)
        let rowsHeight = CGFloat(count) * sessionRowHeight
        let actionsHeight = hasExpandedActions ? expandedActionsHeight : 0
        return min(rowsHeight + actionsHeight, maximumSessionListHeight)
    }

    /// A scroll affordance belongs only to a list whose expanded content
    /// cannot fit in its assigned viewport. Showing it for a fitting row
    /// makes the pointer target move unnecessarily while the row opens.
    public static func requiresScrolling(
        sessionCount: Int,
        hasExpandedActions: Bool
    ) -> Bool {
        let count = max(0, sessionCount)
        let rowsHeight = CGFloat(count) * sessionRowHeight
        let actionsHeight = hasExpandedActions ? expandedActionsHeight : 0
        return rowsHeight + actionsHeight > maximumSessionListHeight
    }
}

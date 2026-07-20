import Foundation

public struct NotchLayout: Equatable, Sendable {
    /// How the bar presents itself, derived from the screen it sits on: a
    /// real camera housing gets the notch-attached bar, every other display
    /// gets a floating Dynamic-Island-style pill.
    public enum Presentation: Equatable, Sendable {
        case notch
        case pill
    }

    public let presentation: Presentation
    public let width: CGFloat
    public let height: CGFloat
    /// Panel height while the session menu hangs below the notch bar.
    public let expandedHeight: CGFloat
    public let originX: CGFloat
    public let originY: CGFloat
    /// Room reserved left of the notch for up to three tools.
    public let leftContentWidth: CGFloat
    /// Room reserved right of the notch for up to two tools — the balanced
    /// wing split gives the right side more than Claude's single slot.
    public let rightContentWidth: CGFloat
    public let notchWidth: CGFloat

    public static let menuMaxHeight: CGFloat = 360
    /// Pill geometry: the capsule floats inside the menu bar with this much
    /// air above and below, so it never hangs over the windows beneath.
    public static let pillVerticalInset: CGFloat = 1
    /// The session menu never hangs narrower than this on pill displays —
    /// a bare pill can be far too slim to read a session list from.
    public static let pillMenuMinWidth: CGFloat = 340
    /// A screen without a menu bar reports zero height; use the standard.
    public static let fallbackMenuBarHeight: CGFloat = 24

    public init(
        screenMinX: CGFloat,
        screenWidth: CGFloat,
        screenMaxY: CGFloat,
        safeAreaTop: CGFloat,
        leftNotchEdgeX: CGFloat?,
        rightNotchEdgeX: CGFloat?,
        menuBarHeight: CGFloat = 0
    ) {
        leftContentWidth = Self.wingWidth(activeToolCount: 3)
        rightContentWidth = Self.wingWidth(activeToolCount: 2)
        let centerX = screenMinX + screenWidth / 2
        if safeAreaTop > 0, let leftNotchEdgeX, let rightNotchEdgeX {
            presentation = .notch
            height = safeAreaTop
            notchWidth = max(rightNotchEdgeX - leftNotchEdgeX, 168)
            width = leftContentWidth + notchWidth + rightContentWidth
            originX = leftNotchEdgeX - leftContentWidth
            originY = screenMaxY - height
        } else {
            presentation = .pill
            // The pill respects the real menu bar height of the display it
            // sits on instead of scaling a fixed fallback up to it, and
            // stays inside that strip rather than overlapping the content
            // below.
            let menuBar = menuBarHeight > 0 ? menuBarHeight : Self.fallbackMenuBarHeight
            height = menuBar - 2 * Self.pillVerticalInset
            notchWidth = 0
            width = max(leftContentWidth + rightContentWidth, Self.pillMenuMinWidth)
            originX = centerX - width / 2
            originY = screenMaxY - Self.pillVerticalInset - height
        }
        expandedHeight = height + Self.menuMaxHeight
    }

    /// Wing width budget: a slot per tool, tighter gaps between them, and
    /// modest end padding — oversized side margins made the bar look
    /// clunky next to its slim vertical insets.
    public static func wingWidth(activeToolCount: Int) -> CGFloat {
        let count = min(max(activeToolCount, 0), AgentTool.allCases.count)
        guard count > 0 else { return 30 }
        return CGFloat(count * 46 + (count - 1) * 5 + 12)
    }

    /// Horizontal paddings positioning the visible silhouette inside the
    /// panel. On notched screens the wings pin themselves against the
    /// camera housing; on pill displays the bar — and the menu when it is
    /// open — stays centered whatever mix of tools is active.
    public func sidePaddings(
        leftWidth: CGFloat,
        rightWidth: CGFloat,
        menuVisible: Bool
    ) -> (leading: CGFloat, trailing: CGFloat) {
        switch presentation {
        case .notch:
            return (leftContentWidth - leftWidth, rightContentWidth - rightWidth)
        case .pill:
            let barWidth = notchWidth + leftWidth + rightWidth
            let contentWidth = menuVisible ? Self.pillMenuMinWidth : barWidth
            let side = (width - contentWidth) / 2
            return (side, side)
        }
    }

    /// Width the session menu card hangs at: it follows the bar on notched
    /// screens and never drops below a readable width on pill displays.
    public func menuCardWidth(barWidth: CGFloat) -> CGFloat {
        switch presentation {
        case .notch: barWidth
        case .pill: max(barWidth, Self.pillMenuMinWidth)
        }
    }
}

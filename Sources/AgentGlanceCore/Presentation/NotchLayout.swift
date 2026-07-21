import Foundation

public struct NotchLayout: Equatable, Sendable {
    /// How the bar presents itself, derived from the screen it sits on: a
    /// real camera housing gets the notch-attached bar, every other display
    /// gets a compact notch-style drop attached to the screen edge.
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
    public let notchWidth: CGFloat
    private let notchLeadingX: CGFloat?

    /// The outer expanded shell is wider than its content so the S-curves can
    /// sweep laterally instead of looking vertically compressed.
    public static let expandedPanelWidth: CGFloat = 800
    /// Session details keep their readable measure while the outer shell adds
    /// forty points of curve room on each side.
    public static let expandedContentWidth: CGFloat = 720
    public static let expandedCurveGutter: CGFloat = 40

    public static func contentWidth(forExpandedPanelWidth panelWidth: CGFloat) -> CGFloat {
        guard panelWidth.isFinite else { return 1 }
        return min(
            expandedContentWidth,
            max(1, panelWidth - 2 * expandedCurveGutter)
        )
    }

    public static let menuMaxHeight: CGFloat = 360
    /// The notchless drop stays attached to the top and uses the complete menu
    /// bar strip without extending into the windows beneath.
    public static let pillBottomInset: CGFloat = 0
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
        let centerX = screenMinX + screenWidth / 2
        // A display narrower than the ideal menu still gets a fully visible
        // panel. Normal macOS displays are comfortably wider than 720 pt.
        let expandedWidth = min(Self.expandedPanelWidth, max(1, screenWidth))
        if safeAreaTop > 0, let leftNotchEdgeX, let rightNotchEdgeX {
            presentation = .notch
            notchLeadingX = leftNotchEdgeX
            height = safeAreaTop
            notchWidth = max(rightNotchEdgeX - leftNotchEdgeX, 168)
            width = expandedWidth
            // Centre the broad expanded card on the physical camera housing,
            // then keep it inside this display. The bar itself remains pinned
            // to the actual notch through `barLeadingOffset`.
            let notchCenterX = (leftNotchEdgeX + rightNotchEdgeX) / 2
            originX = min(
                max(notchCenterX - width / 2, screenMinX),
                screenMinX + screenWidth - width
            )
            originY = screenMaxY - height
        } else {
            presentation = .pill
            notchLeadingX = nil
            // The notchless drop respects the real menu bar height and hangs
            // directly from the screen top without crossing into content.
            let menuBar = menuBarHeight > 0 ? menuBarHeight : Self.fallbackMenuBarHeight
            height = max(1, menuBar - Self.pillBottomInset)
            notchWidth = 0
            width = expandedWidth
            originX = centerX - width / 2
            originY = screenMaxY - height
        }
        expandedHeight = height + Self.menuMaxHeight
    }

    /// Width one status indicator occupies in the compact bar: glyph, a
    /// tight gap, and up to two digits. The slot is fixed and the wing
    /// widths below add up to exactly the rendered content, so no invisible
    /// slack ends up parked at one end of the bar.
    public static let statusIndicatorSlotWidth: CGFloat = 30
    /// Gap between adjacent indicators; shared by the width formula and the
    /// view so both always agree.
    public static let statusIndicatorSpacing: CGFloat = 6
    /// Breathing room at each end of a status wing — equal on both sides so
    /// pill and notch bars keep symmetric outer padding.
    public static let statusWingEdgePadding: CGFloat = 12

    /// Compact status-bar wing sizing: one slot per *visible* indicator —
    /// zero-count kinds claim nothing — plus equal padding on both ends.
    /// A completely quiet bar keeps a minimal footprint for its idle mark.
    public static func statusWingWidth(visibleIndicatorCount: Int, showsIdleMark: Bool) -> CGFloat {
        guard visibleIndicatorCount > 0 else { return showsIdleMark ? 52 : 0 }
        return CGFloat(visibleIndicatorCount) * statusIndicatorSlotWidth
            + CGFloat(max(visibleIndicatorCount - 1, 0)) * statusIndicatorSpacing
            + 2 * statusWingEdgePadding
    }

    /// Horizontal origin of the compact bar inside the broad panel. On a
    /// notched display this preserves the hardware-notch attachment even
    /// though the expanded card is far wider than the collapsed wings.
    public func barLeadingOffset(leftWidth: CGFloat, rightWidth: CGFloat) -> CGFloat {
        switch presentation {
        case .notch:
            return (notchLeadingX ?? originX) - leftWidth - originX
        case .pill:
            return (width - (leftWidth + notchWidth + rightWidth)) / 2
        }
    }

    /// A physical notch needs matching black shoulders even when all visible
    /// status belongs on one side. Mirror the larger wing so the fake extension
    /// meets both hardware corner radii symmetrically; notchless drops retain
    /// only their real content widths.
    public func balancedStatusWingWidths(
        leftWidth: CGFloat,
        rightWidth: CGFloat
    ) -> (left: CGFloat, right: CGFloat) {
        guard presentation == .notch else { return (leftWidth, rightWidth) }
        let width = max(leftWidth, rightWidth)
        return (width, width)
    }
}

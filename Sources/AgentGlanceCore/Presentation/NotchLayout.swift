import Foundation

public struct NotchLayout: Equatable, Sendable {
    /// How the bar presents itself, derived from the screen it sits on: a
    /// real camera housing gets the notch-attached bar, every other display
    /// gets a compact notch-style drop attached to the screen edge.
    public enum Presentation: Equatable, Sendable {
        case notch
        case pill
    }

    public enum StatusWingSide: Equatable, Sendable {
        case left
        case right
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

    /// The outer expanded shell remains just wider than its content so text
    /// can sit close to the straight sides without entering their corners.
    public static let expandedPanelWidth: CGFloat = 800
    /// Session details use nearly all of the panel width; their own row
    /// padding keeps text clear of the small remaining corner gutter.
    public static let expandedContentWidth: CGFloat = 784
    public static let expandedCurveGutter: CGFloat = 8

    public static func contentWidth(forExpandedPanelWidth panelWidth: CGFloat) -> CGFloat {
        guard panelWidth.isFinite else { return 1 }
        return min(
            expandedContentWidth,
            max(1, panelWidth - 2 * expandedCurveGutter)
        )
    }

    /// The panel has room for three expanded rows without creating a nested
    /// scroll surface. Longer lists retain their own bounded scroll view.
    public static let menuMaxHeight = SessionMenuLayout.maximumCardHeight
    /// An optional amount to remove from the menu-bar contribution to the
    /// virtual-notch height.
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
            // A virtual notch must stay entirely within the menu-bar strip so
            // it never overlaps the app content below it.
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
    /// Breathing room at each end of a virtual-pill status wing.
    public static let statusWingEdgePadding: CGFloat = 18
    /// The camera-facing edge of a hardware-notch wing reserves enough room
    /// to keep the counter cluster fully clear of the physical camera cutout.
    /// The right wing ends in a wider count glyph rather than the left wing's
    /// small status glyph, so its outer inset must also clear the shoulder.
    public static let hardwareNotchOuterWingPadding: CGFloat = 8
    public static let hardwareNotchRightOuterWingPadding = HangingNotchMetrics.topShoulderRadius
    public static let hardwareNotchInnerWingPadding: CGFloat = 12
    /// A small empty continuation after a physical notch, just enough to
    /// finish the hanging silhouette without mirroring a status wing.
    public static let hardwareNotchFakeRightWingWidth: CGFloat = 28

    /// The left outer-edge padding for a compact status wing. See the
    /// side-specific properties for the wider right counter clearance.
    public var statusWingEdgePadding: CGFloat {
        switch presentation {
        case .notch: Self.hardwareNotchOuterWingPadding
        case .pill: Self.statusWingEdgePadding
        }
    }

    /// Padding on the outer and camera-facing edges of the left wing.
    public var leftStatusWingLeadingPadding: CGFloat {
        presentation == .notch ? Self.hardwareNotchOuterWingPadding : Self.statusWingEdgePadding
    }

    public var leftStatusWingTrailingPadding: CGFloat {
        presentation == .notch ? Self.hardwareNotchInnerWingPadding : Self.statusWingEdgePadding
    }

    /// Padding on the camera-facing and outer edges of the right wing.
    public var rightStatusWingLeadingPadding: CGFloat {
        presentation == .notch ? Self.hardwareNotchInnerWingPadding : Self.statusWingEdgePadding
    }

    public var rightStatusWingTrailingPadding: CGFloat {
        presentation == .notch ? Self.hardwareNotchRightOuterWingPadding : Self.statusWingEdgePadding
    }

    /// Compact status-bar wing sizing: one slot per *visible* indicator —
    /// zero-count kinds claim nothing — plus the requested edge padding.
    /// A completely quiet bar keeps the same minimum outer clearance as a
    /// populated wing. The optional padding lets the physical notch stay
    /// compact while the virtual pill remains comfortably spaced.
    public static func statusWingWidth(
        visibleIndicatorCount: Int,
        showsIdleMark: Bool,
        edgePadding: CGFloat = NotchLayout.statusWingEdgePadding
    ) -> CGFloat {
        statusWingWidth(
            visibleIndicatorCount: visibleIndicatorCount,
            showsIdleMark: showsIdleMark,
            leadingPadding: edgePadding,
            trailingPadding: edgePadding
        )
    }

    /// Compact status-wing width with independently controllable leading and
    /// trailing insets. Hardware-notch wings use side-specific values so the
    /// camera gap and each outer glyph both receive the required clearance.
    public static func statusWingWidth(
        visibleIndicatorCount: Int,
        showsIdleMark: Bool,
        leadingPadding: CGFloat,
        trailingPadding: CGFloat
    ) -> CGFloat {
        let leading = leadingPadding.isFinite ? max(0, leadingPadding) : 0
        let trailing = trailingPadding.isFinite ? max(0, trailingPadding) : 0
        guard visibleIndicatorCount > 0 else {
            return showsIdleMark ? max(46, 28 + leading + trailing) : 0
        }
        return CGFloat(visibleIndicatorCount) * statusIndicatorSlotWidth
            + CGFloat(max(visibleIndicatorCount - 1, 0)) * statusIndicatorSpacing
            + leading + trailing
    }

    /// Side-aware status-wing width. Keeping the side explicit prevents the
    /// mirrored right wing from accidentally reusing the left wing's insets.
    public func statusWingWidth(
        side: StatusWingSide,
        visibleIndicatorCount: Int,
        showsIdleMark: Bool
    ) -> CGFloat {
        let leadingPadding: CGFloat
        let trailingPadding: CGFloat
        switch side {
        case .left:
            leadingPadding = leftStatusWingLeadingPadding
            trailingPadding = leftStatusWingTrailingPadding
        case .right:
            leadingPadding = rightStatusWingLeadingPadding
            trailingPadding = rightStatusWingTrailingPadding
        }
        return Self.statusWingWidth(
            visibleIndicatorCount: visibleIndicatorCount,
            showsIdleMark: showsIdleMark,
            leadingPadding: leadingPadding,
            trailingPadding: trailingPadding
        )
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

    /// Widths of the expanded header wings flanking the camera cutout,
    /// measured inside the expanded panel. Pill mode has no cutout
    /// (notchWidth == 0), so the wings simply split the panel.
    public func expandedHeaderWingWidths() -> (left: CGFloat, right: CGFloat) {
        switch presentation {
        case .notch:
            let left = max(0, (notchLeadingX ?? originX) - originX)
            return (left, max(0, width - left - notchWidth))
        case .pill:
            return (width / 2, width / 2)
        }
    }

    /// When statuses exist only to the left of the camera, add a simple empty
    /// right wing for a finished silhouette. The real left wing stays intact;
    /// no width is mirrored back into it, and a real right status takes over
    /// as soon as one exists.
    public func balancedStatusWingWidths(
        leftWidth: CGFloat,
        rightWidth: CGFloat
    ) -> (left: CGFloat, right: CGFloat) {
        guard presentation == .notch, leftWidth > 0, rightWidth == 0 else {
            return (leftWidth, rightWidth)
        }
        return (leftWidth, Self.hardwareNotchFakeRightWingWidth)
    }
}

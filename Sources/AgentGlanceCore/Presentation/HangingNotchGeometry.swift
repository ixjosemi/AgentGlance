import CoreGraphics

/// Visual metrics shared by rendering and hit testing. Compact mode already
/// uses most of the menu-bar height for the two opposing curves; expansion
/// exaggerates both radii so the broad card still reads as a hanging drop.
public enum HangingNotchMetrics {
    public static let compactTopShoulderRadius: CGFloat = 10
    public static let expandedTopShoulderRadius: CGFloat = 48
    public static let compactNotchBottomCornerRadius: CGFloat = 16
    public static let compactPillBottomCornerRadius: CGFloat = 14
    public static let expandedBottomCornerRadius: CGFloat = 56
}

/// Shared path geometry for the top-attached notch/drop silhouette. The top
/// edge flares into the screen edge before curving inward to the body, which
/// creates the concave shoulders that a rounded rectangle cannot express.
public enum HangingNotchGeometry {
    public static func path(
        in rect: CGRect,
        topShoulderRadius requestedTopRadius: CGFloat,
        bottomCornerRadius requestedBottomRadius: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        guard rect.width.isFinite,
              rect.height.isFinite,
              rect.width > 0,
              rect.height > 0 else {
            return path
        }

        let topRadius = min(
            sanitizedRadius(requestedTopRadius),
            rect.width / 2
        )
        let bottomRadius = min(
            sanitizedRadius(requestedBottomRadius),
            max(0, (rect.width - 2 * topRadius) / 2)
        )
        // Stretch both curves vertically until they meet. Their horizontal
        // depths stay modest, but the complete side becomes one continuous S
        // with no straight segment at any expanded height.
        let totalRadius = topRadius + bottomRadius
        let topCurveHeight = totalRadius > 0
            ? rect.height * topRadius / totalRadius
            : 0
        let curveJoinY = rect.minY + topCurveHeight
        let leftBodyX = rect.minX + topRadius
        let rightBodyX = rect.maxX - topRadius

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: leftBodyX, y: curveJoinY),
            control: CGPoint(x: leftBodyX, y: rect.minY)
        )
        path.addQuadCurve(
            to: CGPoint(x: leftBodyX + bottomRadius, y: rect.maxY),
            control: CGPoint(x: leftBodyX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rightBodyX - bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rightBodyX, y: curveJoinY),
            control: CGPoint(x: rightBodyX, y: rect.maxY)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rightBodyX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }

    public static func contains(
        _ point: DisplayPoint,
        width: CGFloat,
        height: CGFloat,
        topShoulderRadius: CGFloat,
        bottomCornerRadius: CGFloat
    ) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return false }
        return path(
            in: CGRect(x: 0, y: 0, width: width, height: height),
            topShoulderRadius: topShoulderRadius,
            bottomCornerRadius: bottomCornerRadius
        ).contains(CGPoint(x: point.x, y: point.y))
    }

    private static func sanitizedRadius(_ radius: CGFloat) -> CGFloat {
        radius.isFinite ? max(0, radius) : 0
    }
}

/// Top-leading panel-local event region matching the rendered hanging notch.
/// AppKit and SwiftUI share this model so transparent shoulders and rounded
/// corner pockets pass clicks through instead of behaving like a rectangle.
public struct HangingNotchInteractionRegion: Equatable, Sendable {
    public static let empty = HangingNotchInteractionRegion(
        frame: DisplayFrame(minX: 0, minY: 0, width: 0, height: 0),
        topShoulderRadius: 0,
        bottomCornerRadius: 0
    )

    public let frame: DisplayFrame
    public let topShoulderRadius: CGFloat
    public let bottomCornerRadius: CGFloat

    public init(
        frame: DisplayFrame,
        topShoulderRadius: CGFloat,
        bottomCornerRadius: CGFloat
    ) {
        self.frame = frame
        self.topShoulderRadius = topShoulderRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    public func contains(_ panelLocalPoint: DisplayPoint) -> Bool {
        HangingNotchGeometry.contains(
            DisplayPoint(
                x: panelLocalPoint.x - frame.minX,
                y: panelLocalPoint.y - frame.minY
            ),
            width: frame.width,
            height: frame.height,
            topShoulderRadius: topShoulderRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }
}

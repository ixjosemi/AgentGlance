import Foundation

/// The screen-selection policy is deliberately independent from AppKit so the
/// priority rules remain behaviorally testable. The app layer supplies stable
/// `NSScreenNumber` identifiers and the current pointer/focus facts.
public enum ScreenSelectionMode: String, CaseIterable, Sendable {
    case pointer
    case focusedWindow
    case allDisplays
}

public struct DisplayPoint: Equatable, Sendable {
    public let x: CGFloat
    public let y: CGFloat

    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }
}

public struct DisplayFrame: Equatable, Sendable {
    public let minX: CGFloat
    public let minY: CGFloat
    public let width: CGFloat
    public let height: CGFloat

    public init(minX: CGFloat, minY: CGFloat, width: CGFloat, height: CGFloat) {
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
    }

    public func contains(_ point: DisplayPoint) -> Bool {
        point.x >= minX && point.x < minX + width
            && point.y >= minY && point.y < minY + height
    }
}

public struct DisplaySnapshot: Equatable, Sendable {
    public let id: UInt32
    public let frame: DisplayFrame

    public init(id: UInt32, frame: DisplayFrame) {
        self.id = id
        self.frame = frame
    }
}

public enum ScreenSelection {
    /// Resolves every display that should host a notch. Pointer and focused
    /// modes return one display; all-displays mode retains every connected
    /// display in the AppKit-provided order.
    public static func selectDisplayIDs(
        mode: ScreenSelectionMode,
        pointerLocation: DisplayPoint?,
        focusedDisplayID: UInt32?,
        lastSelectedDisplayID: UInt32?,
        displays: [DisplaySnapshot]
    ) -> [UInt32] {
        guard !displays.isEmpty else { return [] }
        if mode == .allDisplays {
            return displays.map(\.id)
        }
        return selectDisplayID(
            mode: mode,
            pointerLocation: pointerLocation,
            focusedDisplayID: focusedDisplayID,
            lastSelectedDisplayID: lastSelectedDisplayID,
            displays: displays
        ).map { [$0] } ?? []
    }

    public static func selectDisplayID(
        mode: ScreenSelectionMode,
        pointerLocation: DisplayPoint?,
        focusedDisplayID: UInt32?,
        lastSelectedDisplayID: UInt32?,
        displays: [DisplaySnapshot]
    ) -> UInt32? {
        guard !displays.isEmpty else { return nil }
        let availableIDs = Set(displays.map(\.id))
        let pointerDisplayID = pointerLocation.flatMap { location in
            displays.first(where: { $0.frame.contains(location) })?.id
        }
        let focusedID = focusedDisplayID.flatMap { availableIDs.contains($0) ? $0 : nil }
        let lastID = lastSelectedDisplayID.flatMap { availableIDs.contains($0) ? $0 : nil }

        switch mode {
        case .pointer:
            return pointerDisplayID ?? focusedID ?? lastID ?? displays.first?.id
        case .focusedWindow:
            return focusedID ?? pointerDisplayID ?? lastID ?? displays.first?.id
        case .allDisplays:
            return displays.first?.id
        }
    }
}

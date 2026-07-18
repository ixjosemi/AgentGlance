import AppKit
import SwiftUI

import AgentGlanceCore

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that only accepts events inside the visible notch
/// silhouette. The panel itself always spans the expanded height — resizing
/// the window while SwiftUI animates the shape caused a visible glitch — so
/// pass-through for the transparent strip below the notch is handled here.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var interactiveHeight: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        let distanceFromTop = isFlipped ? local.y : bounds.height - local.y
        guard distanceFromTop <= interactiveHeight else { return nil }
        return super.hitTest(point)
    }
}

@MainActor
final class NotchPanelController {
    private let panel: NotchPanel
    private let layout: NotchLayout
    private var hostingView: NotchHostingView<NotchWidgetView>?

    init(store: StateStore) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        layout = NotchLayout(
            screenMinX: screen?.frame.minX ?? 0,
            screenWidth: screen?.frame.width ?? 1_512,
            screenMaxY: screen?.frame.maxY ?? 982,
            safeAreaTop: screen?.safeAreaInsets.top ?? 0,
            leftNotchEdgeX: screen?.auxiliaryTopLeftArea?.maxX,
            rightNotchEdgeX: screen?.auxiliaryTopRightArea?.minX
        )
        panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: layout.width, height: layout.expandedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        let controller = self
        let hostingView = NotchHostingView(rootView: NotchWidgetView(
            store: store,
            contentTopPadding: layout.contentTopPadding,
            notchWidth: layout.notchWidth,
            leftContentWidth: layout.leftContentWidth,
            rightContentWidth: layout.rightContentWidth,
            barHeight: layout.height,
            onMenuVisibilityChange: { controller.setMenuVisible($0) }
        ))
        hostingView.interactiveHeight = layout.height
        self.hostingView = hostingView
        panel.contentView = hostingView
        panel.setFrame(
            NSRect(
                x: layout.originX,
                y: layout.originY + layout.height - layout.expandedHeight,
                width: layout.width,
                height: layout.expandedHeight
            ),
            display: false
        )
    }

    func show() {
        panel.orderFrontRegardless()
    }

    private func setMenuVisible(_ isVisible: Bool) {
        hostingView?.interactiveHeight = isVisible ? layout.expandedHeight : layout.height
    }
}

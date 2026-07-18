import AppKit
import SwiftUI

import AgentGlanceCore

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchPanelController {
    private let panel: NotchPanel

    init(store: StateStore) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let layout = NotchLayout(
            screenMinX: screen?.frame.minX ?? 0,
            screenWidth: screen?.frame.width ?? 1_512,
            screenMaxY: screen?.frame.maxY ?? 982,
            safeAreaTop: screen?.safeAreaInsets.top ?? 0,
            leftNotchEdgeX: screen?.auxiliaryTopLeftArea?.maxX,
            rightNotchEdgeX: screen?.auxiliaryTopRightArea?.minX
        )
        panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: layout.width, height: layout.height),
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
        panel.contentView = NSHostingView(rootView: NotchWidgetView(
            store: store,
            contentTopPadding: layout.contentTopPadding,
            notchWidth: layout.notchWidth
        ))
        positionPanel()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    private func positionPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let layout = NotchLayout(
            screenMinX: screen.frame.minX,
            screenWidth: screen.frame.width,
            screenMaxY: screen.frame.maxY,
            safeAreaTop: screen.safeAreaInsets.top,
            leftNotchEdgeX: screen.auxiliaryTopLeftArea?.maxX,
            rightNotchEdgeX: screen.auxiliaryTopRightArea?.minX
        )
        let origin = NSPoint(
            x: layout.originX,
            y: layout.originY
        )
        panel.setFrameOrigin(origin)
    }
}

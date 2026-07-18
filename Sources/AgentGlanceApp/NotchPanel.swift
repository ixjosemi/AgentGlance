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
    private let layout: NotchLayout
    private var shrinkWorkItem: DispatchWorkItem?

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
        let controller = self
        panel.contentView = NSHostingView(rootView: NotchWidgetView(
            store: store,
            contentTopPadding: layout.contentTopPadding,
            notchWidth: layout.notchWidth,
            leftContentWidth: layout.leftContentWidth,
            rightContentWidth: layout.rightContentWidth,
            barHeight: layout.height,
            onMenuVisibilityChange: { controller.setMenuVisible($0) }
        ))
        panel.setFrame(frame(expanded: false), display: false)
    }

    func show() {
        panel.orderFrontRegardless()
    }

    /// The panel only occupies the notch bar while collapsed so that clicks
    /// below the notch reach whatever window is behind it. It grows before
    /// the menu animates in and shrinks after the menu animates out.
    private func setMenuVisible(_ isVisible: Bool) {
        shrinkWorkItem?.cancel()
        shrinkWorkItem = nil
        if isVisible {
            panel.setFrame(frame(expanded: true), display: true)
            return
        }
        let workItem = DispatchWorkItem { [panel, collapsedFrame = frame(expanded: false)] in
            panel.setFrame(collapsedFrame, display: true)
        }
        shrinkWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
    }

    private func frame(expanded: Bool) -> NSRect {
        let height = expanded ? layout.expandedHeight : layout.height
        return NSRect(
            x: layout.originX,
            y: layout.originY + layout.height - height,
            width: layout.width,
            height: height
        )
    }
}

import AppKit
import SwiftUI

import AgentGlanceCore

final class NotchPanel: NSPanel {
    /// The panel must never steal keyboard focus from the frontmost app —
    /// except while the user edits a session name inline, when the rename
    /// field needs key status to receive typing.
    var allowsKeyboardFocus = false
    override var canBecomeKey: Bool { allowsKeyboardFocus }
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
    private let store: StateStore
    private let panel: NotchPanel
    private var layout: NotchLayout
    private var hostingView: NotchHostingView<NotchWidgetView>?
    private var screenObserver: NSObjectProtocol?

    init(store: StateStore) {
        self.store = store
        layout = Self.currentLayout()
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
        applyLayout()
        // Display changes — docking, resolution switches, lid state —
        // invalidate every notch metric, so the panel re-derives its layout
        // from the current screen instead of keeping the launch-time one.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.layout = Self.currentLayout()
                self.applyLayout()
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func show() {
        panel.orderFrontRegardless()
    }

    private static func currentLayout() -> NotchLayout {
        let screen = NSScreen.main ?? NSScreen.screens.first
        return NotchLayout(
            screenMinX: screen?.frame.minX ?? 0,
            screenWidth: screen?.frame.width ?? 1_512,
            screenMaxY: screen?.frame.maxY ?? 982,
            safeAreaTop: screen?.safeAreaInsets.top ?? 0,
            leftNotchEdgeX: screen?.auxiliaryTopLeftArea?.maxX,
            rightNotchEdgeX: screen?.auxiliaryTopRightArea?.minX
        )
    }

    /// Builds the hosting view for the current layout and pins the panel to
    /// the notch. Rebuilding collapses an open menu, which is the right
    /// outcome when the screen the menu was measured for just changed.
    private func applyLayout() {
        let controller = self
        let hostingView = NotchHostingView(rootView: NotchWidgetView(
            store: store,
            contentTopPadding: layout.contentTopPadding,
            notchWidth: layout.notchWidth,
            leftContentWidth: layout.leftContentWidth,
            rightContentWidth: layout.rightContentWidth,
            barHeight: layout.height,
            onMenuVisibilityChange: { controller.setMenuVisible($0) },
            onKeyboardFocusChange: { controller.setKeyboardFocus($0) }
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
            display: true
        )
    }

    private func setMenuVisible(_ isVisible: Bool) {
        hostingView?.interactiveHeight = isVisible ? layout.expandedHeight : layout.height
    }

    private func setKeyboardFocus(_ wantsKeyboard: Bool) {
        panel.allowsKeyboardFocus = wantsKeyboard
        if wantsKeyboard {
            panel.makeKey()
        } else if panel.isKeyWindow {
            panel.resignKey()
        }
    }
}

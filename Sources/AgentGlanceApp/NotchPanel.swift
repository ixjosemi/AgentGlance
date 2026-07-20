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
    /// 0 means no horizontal limit. The pill claims only its own silhouette
    /// so the menu bar beside it keeps receiving clicks; notch mode keeps
    /// the full wings-and-notch strip interactive.
    var interactiveWidth: CGFloat = 0

    /// The panel never becomes key, so every click arrives as a "first
    /// mouse" while another app is frontmost. Accepting it makes the first
    /// click act immediately instead of being swallowed as activation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        let distanceFromTop = isFlipped ? local.y : bounds.height - local.y
        guard distanceFromTop <= interactiveHeight else { return nil }
        if interactiveWidth > 0 {
            guard abs(local.x - bounds.midX) <= interactiveWidth / 2 else { return nil }
        }
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
    private var activationObserver: NSObjectProtocol?

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
                self?.relayoutIfScreenChanged()
            }
        }
        // The widget follows the screen the user is working on: activating
        // an app on another display moves the key window — and NSScreen.main
        // — there. This panel never activates, so clicking the widget itself
        // does not trigger a jump; the equality check makes every other
        // activation a cheap no-op until the active screen actually changes.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.relayoutIfScreenChanged()
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func show() {
        panel.orderFrontRegardless()
    }

    private func relayoutIfScreenChanged() {
        let current = Self.currentLayout()
        guard current != layout else { return }
        layout = current
        applyLayout()
    }

    private static func currentLayout() -> NotchLayout {
        let screen = NSScreen.main ?? NSScreen.screens.first
        // frame minus visible frame isolates the menu bar strip: the Dock
        // can eat into the sides or bottom of a screen, never into the top
        // edge, so the difference is the real menu bar height.
        let menuBarHeight = screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 0
        return NotchLayout(
            screenMinX: screen?.frame.minX ?? 0,
            screenWidth: screen?.frame.width ?? 1_512,
            screenMaxY: screen?.frame.maxY ?? 982,
            safeAreaTop: screen?.safeAreaInsets.top ?? 0,
            leftNotchEdgeX: screen?.auxiliaryTopLeftArea?.maxX,
            rightNotchEdgeX: screen?.auxiliaryTopRightArea?.minX,
            menuBarHeight: menuBarHeight
        )
    }

    /// Builds the hosting view for the current layout and pins the panel to
    /// the notch. Rebuilding collapses an open menu, which is the right
    /// outcome when the screen the menu was measured for just changed.
    private func applyLayout() {
        let controller = self
        let hostingView = NotchHostingView(rootView: NotchWidgetView(
            store: store,
            layout: layout,
            onInteractiveSizeChange: { controller.setInteractiveSize($0) },
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

    private func setInteractiveSize(_ size: CGSize) {
        hostingView?.interactiveHeight = size.height
        hostingView?.interactiveWidth = size.width
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

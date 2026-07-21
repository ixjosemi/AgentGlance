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
    /// The broad expanded panel reports its visible drop; the compact bar
    /// reports only its attached silhouette. An empty region passes through.
    var interactiveRegion = HangingNotchInteractionRegion.empty

    /// The panel never becomes key, so every click arrives as a "first
    /// mouse" while another app is frontmost. Accepting it makes the first
    /// click act immediately instead of being swallowed as activation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Unlike UIKit, AppKit supplies this point in the receiver's
        // superview coordinates. The interaction frame is hosting-local.
        let local = superview.map { convert(point, from: $0) } ?? point
        let localX = local.x - bounds.minX
        let distanceFromTop = isFlipped
            ? local.y - bounds.minY
            : bounds.maxY - local.y
        guard interactiveRegion.contains(
            DisplayPoint(x: localX, y: distanceFromTop)
        ) else {
            return nil
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
    private var spaceObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var screenTrackingTimer: Timer?
    private var selectedDisplayID: UInt32?
    private var menuIsVisible = false
    private var pendingScreen: NSScreen?
    /// Arms on every screen jump so the bar materialising under an unmoving
    /// pointer does not read as a hover and pop the menu open by itself.
    private var pointerGate = PointerMovementGate()

    init(store: StateStore) {
        self.store = store
        let screen = Self.selectedScreen(lastSelectedDisplayID: nil)
        layout = Self.layout(for: screen)
        selectedDisplayID = Self.displayID(for: screen)
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
                // Workspace activation can arrive before AppKit has updated
                // NSScreen.main, so resolve it on the following main-loop
                // turn instead of reading the previous app's display.
                DispatchQueue.main.async { self?.relayoutIfScreenChanged() }
            }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.relayoutIfScreenChanged()
            }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.relayoutIfScreenChanged()
            }
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.relayoutIfScreenChanged()
            }
        }
        timer.tolerance = 0.05
        screenTrackingTimer = timer
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        screenTrackingTimer?.invalidate()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    private func relayoutIfScreenChanged() {
        let screen = Self.selectedScreen(lastSelectedDisplayID: selectedDisplayID)
        let displayID = Self.displayID(for: screen)
        let current = Self.layout(for: screen)
        let displayChanged = displayID != selectedDisplayID
        guard current != layout || displayChanged else { return }
        guard !menuIsVisible else {
            pendingScreen = screen
            return
        }
        if displayChanged {
            // The bar materialises wherever the pointer's display is; a
            // stationary pointer resting where it lands must not read as a
            // hover and open the menu on its own.
            let mouse = NSEvent.mouseLocation
            pointerGate.lock(at: DisplayPoint(x: mouse.x, y: mouse.y))
        }
        selectedDisplayID = displayID
        layout = current
        applyLayout()
    }

    private static func layout(for screen: NSScreen?) -> NotchLayout {
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

    private static func selectedScreen(lastSelectedDisplayID: UInt32?) -> NSScreen? {
        let screens = NSScreen.screens
        let snapshots = screens.compactMap { screen -> DisplaySnapshot? in
            guard let id = displayID(for: screen) else { return nil }
            return DisplaySnapshot(
                id: id,
                frame: DisplayFrame(
                    minX: screen.frame.minX,
                    minY: screen.frame.minY,
                    width: screen.frame.width,
                    height: screen.frame.height
                )
            )
        }
        let mode = ScreenSelectionMode(
            rawValue: UserDefaults.standard.string(forKey: "screenSelectionMode") ?? ""
        ) ?? .pointer
        // AgentGlance deliberately does not activate for notch clicks. If its
        // own Settings window is key, treating NSScreen.main as user focus
        // would move the widget for an internal UI action; pointer/last are a
        // safer fallback in that case.
        let focusedDisplayID = NSApp.isActive ? nil : displayID(for: NSScreen.main)
        let mouseLocation = NSEvent.mouseLocation
        let selectedID = ScreenSelection.selectDisplayID(
            mode: mode,
            pointerLocation: DisplayPoint(x: mouseLocation.x, y: mouseLocation.y),
            focusedDisplayID: focusedDisplayID,
            lastSelectedDisplayID: lastSelectedDisplayID,
            displays: snapshots
        )
        return screens.first { displayID(for: $0) == selectedID } ?? screens.first
    }

    private static func displayID(for screen: NSScreen?) -> UInt32? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { $0.uint32Value }
    }

    /// Pins the panel to the current layout's notch. The hosting view is
    /// updated in place rather than rebuilt so SwiftUI keeps view identity —
    /// and with it hover and expansion state.
    private func applyLayout() {
        if let hostingView {
            hostingView.rootView = makeRootView()
        } else {
            let hostingView = NotchHostingView(rootView: makeRootView())
            self.hostingView = hostingView
            panel.contentView = hostingView
        }
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

    private func makeRootView() -> NotchWidgetView {
        let controller = self
        return NotchWidgetView(
            store: store,
            layout: layout,
            allowHoverExpansion: { point in
                controller.pointerGate.update(pointerLocation: point)
            },
            onInteractiveRegionChange: { controller.setInteractiveRegion($0) },
            onKeyboardFocusChange: { controller.setKeyboardFocus($0) },
            onMenuVisibilityChange: { controller.setMenuVisibility($0) }
        )
    }

    private func setInteractiveRegion(_ region: HangingNotchInteractionRegion) {
        hostingView?.interactiveRegion = region
    }

    private func setMenuVisibility(_ isVisible: Bool) {
        menuIsVisible = isVisible
        guard !isVisible, pendingScreen != nil else { return }
        pendingScreen = nil
        relayoutIfScreenChanged()
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

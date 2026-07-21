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
    var interactiveRegion = HangingNotchInteractionRegion.empty {
        didSet { refreshPointerLocation() }
    }
    /// A single tracking area covers the fixed-size panel. Its callback then
    /// tests the current hanging silhouette, so resizing the SwiftUI card
    /// never replaces the area that owns hover state.
    var onPointerUpdate: ((Bool, DisplayPoint) -> Void)?
    private var pointerTrackingArea: NSTrackingArea?

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

    override func updateTrackingAreas() {
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        report(event: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        report(event: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        let location = globalLocation(for: event)
        onPointerUpdate?(false, location)
    }

    func refreshPointerLocation() {
        guard let window else { return }
        let global = NSEvent.mouseLocation
        let inWindow = window.convertPoint(fromScreen: NSPoint(x: global.x, y: global.y))
        let local = convert(inWindow, from: nil)
        report(localPoint: local, globalLocation: DisplayPoint(x: global.x, y: global.y))
    }

    private func report(event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        report(localPoint: local, globalLocation: globalLocation(for: event))
    }

    private func report(localPoint: NSPoint, globalLocation: DisplayPoint) {
        let topLeadingY = isFlipped
            ? localPoint.y - bounds.minY
            : bounds.maxY - localPoint.y
        let isInside = interactiveRegion.contains(
            DisplayPoint(x: localPoint.x - bounds.minX, y: topLeadingY)
        )
        onPointerUpdate?(isInside, globalLocation)
    }

    private func globalLocation(for event: NSEvent) -> DisplayPoint {
        guard let window else {
            let location = NSEvent.mouseLocation
            return DisplayPoint(x: location.x, y: location.y)
        }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        return DisplayPoint(x: point.x, y: point.y)
    }
}

/// One independent SwiftUI/AppKit surface for a display. Each surface owns
/// hover, expanded-menu, and keyboard-focus state, which lets all-displays
/// mode show the helper on every connected screen at once.
@MainActor
private final class NotchDisplayPanel {
    private let store: StateStore
    private let panel: NotchPanel
    private var layout: NotchLayout
    private var hostingView: NotchHostingView<NotchWidgetView>?
    private var pointerGate = PointerMovementGate()
    private let pointerTracker = NotchPointerTracker()
    private let onMenuVisibilityChanged: () -> Void

    private(set) var menuIsVisible = false

    init(
        store: StateStore,
        layout: NotchLayout,
        onMenuVisibilityChanged: @escaping () -> Void
    ) {
        self.store = store
        self.layout = layout
        self.onMenuVisibilityChanged = onMenuVisibilityChanged
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
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func update(layout: NotchLayout) {
        guard layout != self.layout else { return }
        self.layout = layout
        applyLayout()
    }

    func lockHoverExpansion(at point: DisplayPoint) {
        pointerGate.lock(at: point)
    }

    private func applyLayout() {
        if let hostingView {
            hostingView.rootView = makeRootView()
        } else {
            let hostingView = NotchHostingView(rootView: makeRootView())
            hostingView.onPointerUpdate = { [weak pointerTracker] isInside, location in
                pointerTracker?.update(isInside: isInside, location: location)
            }
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
        NotchWidgetView(
            store: store,
            layout: layout,
            allowHoverExpansion: { [weak self] point in
                self?.pointerGate.update(pointerLocation: point) ?? false
            },
            pointerTracker: pointerTracker,
            requestPointerRefresh: { [weak self] in
                self?.hostingView?.refreshPointerLocation()
            },
            onInteractiveRegionChange: { [weak self] region in
                self?.hostingView?.interactiveRegion = region
            },
            onKeyboardFocusChange: { [weak self] wantsKeyboard in
                self?.setKeyboardFocus(wantsKeyboard)
            },
            onMenuVisibilityChange: { [weak self] isVisible in
                guard let self else { return }
                menuIsVisible = isVisible
                onMenuVisibilityChanged()
            }
        )
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

@MainActor
final class NotchPanelController {
    private let store: StateStore
    private var displayPanels: [UInt32: NotchDisplayPanel] = [:]
    private var selectedDisplayID: UInt32?
    private var panelsAreVisible = false
    /// A pointer/focus move waits for the current menu to close. All-displays
    /// mode has no selected display and therefore never needs this deferral.
    private var hasPendingSelectedDisplay = false
    private var screenObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var screenTrackingTimer: Timer?

    init(store: StateStore) {
        self.store = store
        synchronizePanels()
        // Display changes — docking, resolution switches, lid state —
        // invalidate every notch metric, so every panel re-derives its layout
        // from the current screen instead of keeping launch-time values.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.synchronizePanels()
            }
        }
        // The widget follows the screen the user is working on when a
        // single-display policy is active. All-displays mode deliberately
        // keeps every panel visible regardless of activation.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.async { self?.synchronizePanels() }
            }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.synchronizePanels()
            }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.synchronizePanels()
            }
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.synchronizePanels()
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
        panelsAreVisible = true
        displayPanels.values.forEach { $0.show() }
    }

    private func synchronizePanels() {
        let screens = NSScreen.screens
        let screensByID = screens.reduce(into: [UInt32: NSScreen]()) { result, screen in
            guard let displayID = Self.displayID(for: screen) else { return }
            result[displayID] = screen
        }
        let displays = screens.compactMap { screen -> DisplaySnapshot? in
            guard let displayID = Self.displayID(for: screen) else { return nil }
            return DisplaySnapshot(
                id: displayID,
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
        // would move a single selected helper for an internal UI action.
        let focusedDisplayID = NSApp.isActive ? nil : Self.displayID(for: NSScreen.main)
        let mouseLocation = NSEvent.mouseLocation
        let desiredIDs = ScreenSelection.selectDisplayIDs(
            mode: mode,
            pointerLocation: DisplayPoint(x: mouseLocation.x, y: mouseLocation.y),
            focusedDisplayID: focusedDisplayID,
            lastSelectedDisplayID: selectedDisplayID,
            displays: displays
        )
        let desiredIDSet = Set(desiredIDs)

        if mode != .allDisplays,
           let desiredID = desiredIDs.first,
           let currentID = selectedDisplayID,
           currentID != desiredID,
           displayPanels[currentID]?.menuIsVisible == true {
            hasPendingSelectedDisplay = true
            return
        }

        let previousSelectedDisplayID = selectedDisplayID
        selectedDisplayID = mode == .allDisplays ? nil : desiredIDs.first
        hasPendingSelectedDisplay = false

        for displayID in desiredIDs {
            guard let screen = screensByID[displayID] else { continue }
            let layout = Self.layout(for: screen)
            if let displayPanel = displayPanels[displayID] {
                displayPanel.update(layout: layout)
            } else {
                let displayPanel = NotchDisplayPanel(
                    store: store,
                    layout: layout,
                    onMenuVisibilityChanged: { [weak self] in
                        self?.handleMenuVisibilityChange()
                    }
                )
                displayPanels[displayID] = displayPanel
                if panelsAreVisible {
                    displayPanel.show()
                }
                if mode != .allDisplays,
                   let previousSelectedDisplayID,
                   previousSelectedDisplayID != displayID {
                    let mouse = NSEvent.mouseLocation
                    displayPanel.lockHoverExpansion(at: DisplayPoint(x: mouse.x, y: mouse.y))
                }
            }
        }

        let removedDisplayIDs = displayPanels.keys.filter { !desiredIDSet.contains($0) }
        for displayID in removedDisplayIDs {
            displayPanels[displayID]?.hide()
            displayPanels.removeValue(forKey: displayID)
        }
    }

    private func handleMenuVisibilityChange() {
        guard hasPendingSelectedDisplay,
              !displayPanels.values.contains(where: \.menuIsVisible) else { return }
        synchronizePanels()
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

    private static func displayID(for screen: NSScreen?) -> UInt32? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { $0.uint32Value }
    }
}

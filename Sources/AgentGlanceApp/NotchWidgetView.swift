import AppKit
import SwiftUI

import AgentGlanceCore

struct NotchWidgetView: View {
    @Bindable var store: StateStore
    @AppStorage("hideWhenEmpty") private var hideWhenEmpty = false
    let notchWidth: CGFloat
    let leftContentWidth: CGFloat
    let rightContentWidth: CGFloat
    let barHeight: CGFloat
    let onMenuVisibilityChange: (Bool) -> Void
    let onKeyboardFocusChange: (Bool) -> Void

    @State private var expandedTool: AgentTool?
    @State private var collapseWorkItem: DispatchWorkItem?
    @State private var isHoveringPanel = false
    @State private var openMenuTrackingCount = 0
    @State private var rowInteractionActive = false
    @State private var outsideClickMonitor: Any?

    var body: some View {
        // The bar semaphore ignores waiting sessions the user has already
        // visited; the menu below keeps showing their real status.
        let placement = NotchWingPlacement.place(
            ToolSummary.active(in: store.acknowledgments.silenced(store.sessions))
        )
        let isEmpty = placement.leftWing.isEmpty && placement.rightWing.isEmpty
        let shouldHide = isEmpty && hideWhenEmpty
        let leftWidth = wingWidth(placement.leftWing, idleDot: isEmpty)
        let rightWidth = wingWidth(placement.rightWing, idleDot: false)

        let barWidth = leftWidth + notchWidth + rightWidth
        let isExpanded = expandedTool != nil

        // Bar and menu share one background silhouette so the expanded menu
        // grows out of the notch as a single continuous shape — no seam, no
        // overlap tricks.
        ZStack(alignment: .top) {
            if !shouldHide {
                VStack(spacing: 0) {
                    barRow(placement: placement, isEmpty: isEmpty, leftWidth: leftWidth, rightWidth: rightWidth)
                        .frame(width: barWidth, height: barHeight, alignment: .top)
                    if let expandedTool {
                        SessionMenuCard(
                            tool: expandedTool,
                            sessions: store.sessions(for: expandedTool),
                            dismiss: collapseMenu,
                            acknowledge: { store.acknowledge($0) },
                            sessionTitle: { store.displayName(for: $0) },
                            overrideName: { store.nameOverrides.displayName(for: $0) },
                            rename: { store.rename($0, to: $1) },
                            setKeyboardFocus: onKeyboardFocusChange,
                            onRowInteractionChange: { isActive in
                                rowInteractionActive = isActive
                                if !isActive { settleAfterDetachedInteraction() }
                            }
                        )
                        .frame(width: barWidth)
                        .transition(.opacity)
                    }
                }
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: isExpanded ? 20 : 12,
                        bottomTrailingRadius: isExpanded ? 20 : 12,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                    .fill(.black)
                    .shadow(color: .black.opacity(isExpanded ? 0.45 : 0), radius: 18, y: 8)
                )
                // Hover and the context menu belong to the silhouette, not
                // the outer frame: the panel is always expanded-height, so
                // the outer frame covers transparent dead space below.
                .contextMenu {
                    SettingsLink {
                        Label("AgentGlance Settings", systemImage: "gearshape")
                    }
                    Divider()
                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Label("Quit AgentGlance", systemImage: "power")
                    }
                }
                .onHover { isHovering in
                    isHoveringPanel = isHovering
                    scheduleCollapseOnHoverExit(isHovering)
                }
                // A session row's context menu is an NSMenu window outside
                // this view: opening it fires a hover exit that would
                // collapse the panel — and the menu with it — mid-read.
                .onReceive(
                    NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
                ) { _ in
                    openMenuTrackingCount += 1
                    collapseWorkItem?.cancel()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
                ) { _ in
                    openMenuTrackingCount = max(0, openMenuTrackingCount - 1)
                    settleAfterDetachedInteraction()
                }
                .padding(.leading, leftContentWidth - leftWidth)
                .padding(.trailing, rightContentWidth - rightWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: expandedTool)
        .onChange(of: expandedTool != nil) { _, isVisible in
            onMenuVisibilityChange(isVisible)
            updateOutsideClickMonitor(menuIsVisible: isVisible)
        }
        .onDisappear { updateOutsideClickMonitor(menuIsVisible: false) }
        // Killing or losing the last session of the expanded tool leaves
        // nothing to show — and the tool's own bar icon disappears with it —
        // so the menu closes itself instead of floating over an empty list.
        .onChange(of: expandedTool.map { store.sessions(for: $0).isEmpty } ?? false) { _, isNowEmpty in
            if isNowEmpty { collapseMenu() }
        }
    }

    // MARK: Bar

    private func barRow(
        placement: NotchWingPlacement,
        isEmpty: Bool,
        leftWidth: CGFloat,
        rightWidth: CGFloat
    ) -> some View {
        // Wings span the full bar height so the click targets reach the top
        // edge of the screen — the natural place to slam the pointer.
        HStack(spacing: 0) {
            wingContent(placement.leftWing, idleDot: isEmpty)
                .frame(width: leftWidth, height: barHeight)
            Color.clear
                .frame(width: notchWidth, height: barHeight)
            wingContent(placement.rightWing, idleDot: false)
                .frame(width: rightWidth, height: barHeight)
        }
    }

    private func wingWidth(_ wing: [ToolSummary], idleDot: Bool) -> CGFloat {
        if wing.isEmpty {
            return idleDot ? 30 : 0
        }
        return NotchLayout.wingWidth(activeToolCount: wing.count)
    }

    @ViewBuilder
    private func wingContent(_ wing: [ToolSummary], idleDot: Bool) -> some View {
        if wing.isEmpty {
            if idleDot {
                // Quiet empty state: the app is awake but no agent is running.
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.32))
                    .accessibilityLabel("No active agents")
            }
        } else {
            HStack(spacing: 6) {
                ForEach(wing, id: \.tool) { summary in
                    ToolIndicator(
                        summary: summary,
                        isExpanded: expandedTool == summary.tool,
                        toggle: { toggleMenu(for: summary.tool) }
                    )
                }
            }
            .padding(.horizontal, 10)
        }
    }

    // MARK: Menu visibility

    private func toggleMenu(for tool: AgentTool) {
        collapseWorkItem?.cancel()
        expandedTool = expandedTool == tool ? nil : tool
    }

    private func collapseMenu() {
        collapseWorkItem?.cancel()
        expandedTool = nil
    }

    /// Collapse shortly after the pointer leaves the notch surface, mirroring
    /// how notch utilities dismiss; the grace period tolerates brief exits.
    /// While a menu is open or a row interaction — inline rename, kill
    /// confirmation — is underway, collapsing is deferred until it ends.
    private func scheduleCollapseOnHoverExit(_ isHovering: Bool) {
        collapseWorkItem?.cancel()
        guard !isHovering,
              expandedTool != nil,
              openMenuTrackingCount == 0,
              !rowInteractionActive else { return }
        let workItem = DispatchWorkItem { expandedTool = nil }
        collapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    /// After a menu or modal dialog closes, no hover event fires if the
    /// pointer already sits outside the panel — re-arm the collapse manually
    /// so the panel never sticks open.
    private func settleAfterDetachedInteraction() {
        guard !isHoveringPanel else { return }
        scheduleCollapseOnHoverExit(false)
    }

    /// A click anywhere outside the app dismisses the open menu immediately,
    /// the way any system menu behaves. Global monitors never see events in
    /// our own windows, so clicks inside the panel are unaffected; they also
    /// bypass the hover grace period and the row-interaction lock — clicking
    /// elsewhere is an unambiguous "I am done here".
    private func updateOutsideClickMonitor(menuIsVisible: Bool) {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        guard menuIsVisible else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { _ in
            collapseMenu()
        }
    }
}

// MARK: - Tool indicator

private struct ToolIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let summary: ToolSummary
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var attentionIsBright = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                AgentIconView(tool: summary.tool)
                if summary.sessionCount > 0 {
                    Text(summary.sessionCount, format: .number)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }
                // Working is the default hum of the app — no light. The bar
                // only signals waiting states: yellow (idle, waiting for a
                // prompt) and red (waiting on an answer or a permission).
                if let worstStatus = summary.worstStatus, worstStatus != .working {
                    Circle()
                        .fill(semaphoreColor(for: worstStatus))
                        .frame(width: 6, height: 6)
                        .opacity(pulseOpacity(for: worstStatus))
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                                attentionIsBright = true
                            }
                        }
                }
            }
            .frame(minWidth: 50, minHeight: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(isExpanded ? 0.12 : 0))
            )
            // The visible pill stays 24 pt tall, but the tappable area
            // covers the whole bar strip — no dead pixels between the pill
            // and the screen edge.
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(summary.sessionCount == 0 ? 0.3 : 0.92))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Only the red light pulses; green and yellow stay steady so the bar
    /// never draws attention when nothing needs it.
    private func pulseOpacity(for status: SessionStatus) -> Double {
        guard status == .needsAttention, !reduceMotion else { return 1 }
        return attentionIsBright ? 1 : 0.35
    }

    private var accessibilityLabel: String {
        let attention = summary.needsAttention ? ", needs attention" : ""
        return "\(summary.tool.rawValue), \(summary.sessionCount) sessions\(attention)"
    }
}

private let sessionRowHeight: CGFloat = 46

/// The green light of an actively working session emits a radar-style ping:
/// continuous activity, in the semaphore's own visual language — a spinner
/// would wrongly suggest a bounded loading task.
private struct WorkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPinging = false

    var body: some View {
        ZStack {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
            if !reduceMotion {
                Circle()
                    .stroke(.green.opacity(0.7), lineWidth: 1.5)
                    .frame(width: 8, height: 8)
                    .scaleEffect(isPinging ? 2.4 : 1)
                    .opacity(isPinging ? 0 : 0.7)
                    .onAppear {
                        withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                            isPinging = true
                        }
                    }
            }
        }
        .frame(width: 8, height: 8)
    }
}

/// Traffic-light mapping shared by the bar semaphores and the menu rows:
/// green = working, yellow = idle, red = waiting on the user.
private func semaphoreColor(for status: SessionStatus) -> Color {
    switch status {
    case .working: .green
    case .idle: .yellow
    case .needsAttention: .red
    case .ended: .gray
    }
}

// MARK: - Brand icons

/// SVG brand marks bundled in AgentGlanceCore; NSImage renders SVG natively
/// on macOS 11+ so no rasterized assets are needed.
private enum AgentIcons {
    static let byTool: [AgentTool: NSImage] = Dictionary(
        uniqueKeysWithValues: AgentTool.allCases.compactMap { tool in
            NSImage(contentsOf: BundledResources.iconURL(for: tool)).map { (tool, $0) }
        }
    )
}

private struct AgentIconView: View {
    let tool: AgentTool

    var body: some View {
        if let image = AgentIcons.byTool[tool] {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 15, height: 15)
                .accessibilityHidden(true)
        } else {
            Text(String(tool.rawValue.prefix(1)).uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .frame(width: 15, height: 15)
                .overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 1))
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Session menu

private struct SessionMenuCard: View {
    let tool: AgentTool
    let sessions: [AgentSession]
    let dismiss: () -> Void
    let acknowledge: (AgentSession) -> Void
    let sessionTitle: (AgentSession) -> String
    let overrideName: (AgentSession) -> String?
    let rename: (AgentSession, String) -> Void
    let setKeyboardFocus: (Bool) -> Void
    let onRowInteractionChange: (Bool) -> Void
    @State private var errorMessage: String?
    // At most one row shows its inline actions; opening another closes it.
    @State private var actionsSessionID: String?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                AgentIconView(tool: tool)
                Text(displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text(sessions.count, format: .number)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.35))
                SettingsGearButton {
                    // The settings window is a normal app window: activate
                    // first so it opens frontmost and key — the notch panel
                    // itself never takes that role.
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                    dismiss()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)

            if sessions.isEmpty {
                Text("No active sessions")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            } else if sessions.count <= 5 {
                VStack(spacing: 0) {
                    ForEach(sessions) { session in
                        row(for: session)
                    }
                }
                .padding(.bottom, 8)
            } else {
                // Half a row peeks out at the cutoff to hint at the scroll.
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(sessions) { session in
                            row(for: session)
                        }
                    }
                }
                .frame(height: 5.5 * sessionRowHeight)
                .padding(.bottom, 8)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
        // The whole panel can collapse while a row interaction is open;
        // the interaction lock must not outlive the card.
        .onDisappear { onRowInteractionChange(false) }
    }

    private func row(for session: AgentSession) -> some View {
        SessionRow(
            session: session,
            title: sessionTitle(session),
            renamePrefill: overrideName(session) ?? "",
            isActionsExpanded: actionsSessionID == session.id,
            toggleActions: { toggleActions(for: session) },
            focus: focusSession,
            rename: rename,
            kill: killSession,
            setKeyboardFocus: setKeyboardFocus
        )
    }

    private func toggleActions(for session: AgentSession) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            actionsSessionID = actionsSessionID == session.id ? nil : session.id
        }
        onRowInteractionChange(actionsSessionID != nil)
    }

    private var displayName: String {
        switch tool {
        case .claude: "Claude Code"
        case .convoy: "Convoy"
        case .opencode: "OpenCode"
        case .codex: "Codex"
        case .pi: "Pi"
        }
    }

    /// The kill waits up to two grace periods; keep it off the main thread.
    /// The state document needs no cleanup here: the scheduler's exit
    /// watcher sees the death and the reaper removes it on its tick.
    private func killSession(_ session: AgentSession) {
        Task.detached(priority: .userInitiated) {
            do {
                try TerminationService.terminate(session)
            } catch {
                await MainActor.run {
                    errorMessage = "Could not kill this session."
                }
            }
        }
    }

    private func focusSession(_ session: AgentSession) {
        // FocusService shells out to osascript/tmux, which can take
        // hundreds of milliseconds; keep it off the main thread so the
        // menu stays responsive.
        Task.detached(priority: .userInitiated) {
            do {
                try FocusService.focus(session)
                await MainActor.run {
                    acknowledge(session)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Could not focus this terminal session."
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let title: String
    let renamePrefill: String
    let isActionsExpanded: Bool
    let toggleActions: () -> Void
    let focus: (AgentSession) -> Void
    let rename: (AgentSession, String) -> Void
    let kill: (AgentSession) -> Void
    let setKeyboardFocus: (Bool) -> Void

    /// Sub-modes of the inline action area: the button strip, the rename
    /// field, or the kill confirmation. All live inside the row itself so
    /// nothing ever floats outside the notch silhouette.
    private enum ActionMode { case menu, renaming, confirmingKill }

    @State private var isHovered = false
    @State private var branchName: String?
    @State private var mode: ActionMode = .menu
    @State private var renameDraft = ""
    @FocusState private var renameFieldIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    focus(session)
                } label: {
                    mainRow.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The chevron sits beside — not inside — the focus button,
                // so each click has exactly one unambiguous target.
                chevronButton
                    .padding(.trailing, 12)
            }
            // A right (or control) click also expands the actions inline;
            // the catcher passes every other event through.
            .overlay(RightClickCatcher(onRightClick: toggleActions))
            if isActionsExpanded {
                actionArea
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(isHovered || isActionsExpanded ? 0.08 : 0))
                .padding(.horizontal, 6)
        )
        .onHover { isHovered = $0 }
        .onChange(of: isActionsExpanded) { _, _ in
            endRenameKeyboard()
            mode = .menu
        }
        .onDisappear { endRenameKeyboard() }
        // Resolving the branch reads .git/HEAD from disk; the render path
        // must not pay for it on every body evaluation. Menu rows are
        // transient, so a branch switched mid-display refreshes on the
        // next open.
        .task(id: session.cwd) { [cwd = session.cwd] in
            branchName = await Task.detached {
                GitWorkspaceInspector.branchName(forWorkingDirectory: cwd)
            }.value
        }
        .accessibilityLabel("\(title), \(session.status.rawValue)")
    }

    private var mainRow: some View {
        HStack(spacing: 10) {
            if session.status == .working {
                WorkingIndicator()
            } else {
                Circle()
                    .fill(semaphoreColor(for: session.status))
                    .frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)
                // The title belongs to the tab now, so the directory keeps
                // the project context here, followed by the pipeline step —
                // which outranks the branch: convoy targets worktrees whose
                // directory name already carries it — or the git branch.
                HStack(spacing: 3) {
                    Image(systemName: "folder")
                        .font(.system(size: 8, weight: .semibold))
                    Text(SessionTitleFormatter.truncate(session.projectName, to: 14))
                        .font(.system(size: 10, design: .monospaced))
                    if let currentStep = session.currentStep {
                        Text("·")
                        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                            .font(.system(size: 8, weight: .semibold))
                        Text(currentStep)
                            .font(.system(size: 10, design: .monospaced))
                    } else if let branch = branchName {
                        Text("·")
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 8, weight: .semibold))
                        Text(branch)
                            .font(.system(size: 10, design: .monospaced))
                    }
                }
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            // The system wakes this view on minute boundaries while the
            // row is on screen — no timers, no polling while collapsed.
            TimelineView(.everyMinute) { context in
                Text(SessionDurationFormatter.string(from: session.startedAt, to: context.date))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: sessionRowHeight)
    }

    private var chevronButton: some View {
        Button(action: toggleActions) {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovered || isActionsExpanded ? 0.65 : 0.3))
                .rotationEffect(.degrees(isActionsExpanded ? 180 : 0))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.white.opacity(isActionsExpanded ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Session actions")
    }

    @ViewBuilder
    private var actionArea: some View {
        switch mode {
        case .menu:
            VStack(spacing: 1) {
                ActionListRow(label: "Rename Session", systemImage: "pencil") {
                    beginRename()
                }
                ActionListRow(label: "Copy Project Path", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.cwd, forType: .string)
                    toggleActions()
                }
                ActionListRow(label: "Reveal in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: session.cwd)]
                    )
                    toggleActions()
                }
                ActionListRow(
                    label: "Kill Session",
                    systemImage: "xmark.octagon",
                    isDestructive: true
                ) {
                    mode = .confirmingKill
                }
            }
        case .renaming:
            HStack(spacing: 6) {
                TextField(session.projectName, text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.92))
                    .focused($renameFieldIsFocused)
                    .onSubmit(commitRename)
                    .onExitCommand(perform: cancelRename)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.white.opacity(0.1))
                    )
                iconButton("checkmark", accessibilityLabel: "Save name", action: commitRename)
                iconButton("xmark", accessibilityLabel: "Cancel rename", action: cancelRename)
            }
        case .confirmingKill:
            HStack(spacing: 8) {
                Text("Kill the process and close its pane?")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Spacer(minLength: 0)
                ActionListRow(
                    label: "Kill",
                    systemImage: "xmark.octagon",
                    isDestructive: true,
                    fillsWidth: false
                ) {
                    kill(session)
                    toggleActions()
                }
                ActionListRow(label: "Cancel", systemImage: "arrow.uturn.backward", fillsWidth: false) {
                    mode = .menu
                }
            }
        }
    }

    private func iconButton(
        _ systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func beginRename() {
        renameDraft = renamePrefill
        mode = .renaming
        // The panel refuses key status except during this edit; grant it
        // first, then focus the field once the window can accept it.
        setKeyboardFocus(true)
        DispatchQueue.main.async { renameFieldIsFocused = true }
    }

    private func commitRename() {
        rename(session, renameDraft)
        endRenameKeyboard()
        toggleActions()
    }

    private func cancelRename() {
        endRenameKeyboard()
        mode = .menu
    }

    private func endRenameKeyboard() {
        guard mode == .renaming else { return }
        renameFieldIsFocused = false
        setKeyboardFocus(false)
    }
}

/// The visible route into the native Settings window, living in the menu
/// header; the silhouette's right-click menu stays as the fallback for when
/// no sessions exist and no menu can open.
private struct SettingsGearButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovered ? 0.75 : 0.35))
                .frame(width: 18, height: 18)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("AgentGlance settings")
    }
}

/// One entry of the inline action list: icon, label, hover highlight — the
/// look of a menu item, rendered inside the row instead of a floating menu.
private struct ActionListRow: View {
    let label: String
    let systemImage: String
    var isDestructive = false
    /// List entries span the row; the kill-confirmation buttons keep their
    /// natural width so the question stays on the same line.
    var fillsWidth = true
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 15)
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                if fillsWidth {
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(
                isDestructive
                    ? Color.red.opacity(isHovered ? 1 : 0.85)
                    : Color.white.opacity(isHovered ? 0.95 : 0.8)
            )
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundOpacity)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var backgroundOpacity: Color {
        if isDestructive && isHovered {
            return .red.opacity(0.18)
        }
        let restingOpacity = fillsWidth ? 0.0 : 0.08
        return .white.opacity(isHovered ? 0.1 : restingOpacity)
    }
}

/// Claims right and control clicks for the inline action toggle and lets
/// every other event — left clicks, hover, scroll — fall through to the
/// SwiftUI row underneath.
private struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> RightClickForwardingView {
        let view = RightClickForwardingView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: RightClickForwardingView, context: Context) {
        view.onRightClick = onRightClick
    }
}

private final class RightClickForwardingView: NSView {
    var onRightClick: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    override func mouseDown(with event: NSEvent) {
        // Control-click is the trackpad spelling of a right click.
        if event.modifierFlags.contains(.control) {
            onRightClick?()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)),
              let event = NSApp.currentEvent else {
            return nil
        }
        switch event.type {
        case .rightMouseDown, .rightMouseUp:
            return self
        case .leftMouseDown where event.modifierFlags.contains(.control):
            return self
        default:
            return nil
        }
    }
}

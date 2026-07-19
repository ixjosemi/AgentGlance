import AppKit
import SwiftUI

import AgentGlanceCore

struct NotchWidgetView: View {
    @Bindable var store: StateStore
    @AppStorage("hideWhenEmpty") private var hideWhenEmpty = false
    let contentTopPadding: CGFloat
    let notchWidth: CGFloat
    let leftContentWidth: CGFloat
    let rightContentWidth: CGFloat
    let barHeight: CGFloat
    let onMenuVisibilityChange: (Bool) -> Void

    @State private var expandedTool: AgentTool?
    @State private var collapseWorkItem: DispatchWorkItem?

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
                            acknowledge: { store.acknowledge($0) }
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
                .onHover(perform: scheduleCollapseOnHoverExit)
                .padding(.leading, leftContentWidth - leftWidth)
                .padding(.trailing, rightContentWidth - rightWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: expandedTool)
        .onChange(of: expandedTool != nil) { _, isVisible in
            onMenuVisibilityChange(isVisible)
        }
    }

    // MARK: Bar

    private func barRow(
        placement: NotchWingPlacement,
        isEmpty: Bool,
        leftWidth: CGFloat,
        rightWidth: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            wingContent(placement.leftWing, idleDot: isEmpty)
                .frame(width: leftWidth, height: 24)
            Color.clear
                .frame(width: notchWidth, height: 24)
            wingContent(placement.rightWing, idleDot: false)
                .frame(width: rightWidth, height: 24)
        }
        .padding(.top, contentTopPadding)
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
    private func scheduleCollapseOnHoverExit(_ isHovering: Bool) {
        collapseWorkItem?.cancel()
        guard !isHovering, expandedTool != nil else { return }
        let workItem = DispatchWorkItem { expandedTool = nil }
        collapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
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
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(summary.sessionCount == 0 ? 0.3 : 0.92))
        .frame(minWidth: 50, minHeight: 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(isExpanded ? 0.12 : 0))
        )
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
    @State private var errorMessage: String?

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
                        SessionRow(session: session, focus: focusSession)
                    }
                }
                .padding(.bottom, 8)
            } else {
                // Half a row peeks out at the cutoff to hint at the scroll.
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(sessions) { session in
                            SessionRow(session: session, focus: focusSession)
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
    }

    private var displayName: String {
        switch tool {
        case .claude: "Claude Code"
        case .opencode: "OpenCode"
        case .codex: "Codex"
        case .pi: "Pi"
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
    let focus: (AgentSession) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            focus(session)
        } label: {
            HStack(spacing: 10) {
                if session.status == .working {
                    WorkingIndicator()
                } else {
                    Circle()
                        .fill(semaphoreColor(for: session.status))
                        .frame(width: 8, height: 8)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if let branch = branchName {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 8, weight: .semibold))
                                Text(branch)
                                    .font(.system(size: 10, design: .monospaced))
                            }
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                        }
                        if branchName != nil, tabTitle != nil {
                            Text("·")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.25))
                        }
                        if let tabTitle {
                            Text(tabTitle)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.38))
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 8)
                if let terminalName {
                    Text(terminalName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.1)))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: sessionRowHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(isHovered ? 0.08 : 0))
                    .padding(.horizontal, 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(session.projectName), \(session.status.rawValue)")
    }

    private var branchName: String? {
        GitWorkspaceInspector.branchName(forWorkingDirectory: session.cwd)
    }

    private var tabTitle: String? {
        guard let hint = session.terminal.windowTitleHint, !hint.isEmpty else { return nil }
        return hint
    }

    private var terminalName: String? {
        switch session.terminal.termProgram {
        case "ghostty": "Ghostty"
        case "iTerm.app": "iTerm"
        case "Apple_Terminal": "Terminal"
        case let other?: other
        case nil: nil
        }
    }
}

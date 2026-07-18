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
        let placement = NotchWingPlacement.place(ToolSummary.active(in: store.sessions))
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
                            dismiss: collapseMenu
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
                .padding(.leading, leftContentWidth - leftWidth)
                .padding(.trailing, rightContentWidth - rightWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: expandedTool)
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
                Circle()
                    .fill(.white.opacity(0.5))
                    .frame(width: 7, height: 7)
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
                if summary.needsAttention {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                        .opacity(reduceMotion ? 1 : (attentionIsBright ? 1 : 0.35))
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

    private var accessibilityLabel: String {
        let attention = summary.needsAttention ? ", needs attention" : ""
        return "\(summary.tool.rawValue), \(summary.sessionCount) sessions\(attention)"
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
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                AgentIconView(tool: tool)
                Text(displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
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
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(sessions) { session in
                            SessionRow(session: session, focus: focusSession)
                        }
                    }
                }
                .frame(maxHeight: 280)
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
        }
    }

    private func focusSession(_ session: AgentSession) {
        // FocusService shells out to osascript/tmux, which can take
        // hundreds of milliseconds; keep it off the main thread so the
        // menu stays responsive.
        Task.detached(priority: .userInitiated) {
            do {
                try FocusService.focus(session)
                await MainActor.run { dismiss() }
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
                Circle()
                    .fill(semaphoreColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let branch = branchName {
                            Label(branch, systemImage: "arrow.triangle.branch")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                        if let tabTitle = session.terminal.windowTitleHint, !tabTitle.isEmpty {
                            Text(tabTitle)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.4))
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 8)
                if let terminalName {
                    Text(terminalName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.1)))
                }
                Text(session.updatedAt, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
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

    /// Traffic-light mapping: green = working, yellow = idle,
    /// red = waiting on the user.
    private var semaphoreColor: Color {
        switch session.status {
        case .working: .green
        case .idle: .yellow
        case .needsAttention: .red
        case .ended: .gray
        }
    }

    private var branchName: String? {
        GitWorkspaceInspector.branchName(forWorkingDirectory: session.cwd)
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

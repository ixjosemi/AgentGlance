import AppKit
import SwiftUI

import AgentGlanceCore

struct NotchWidgetView: View {
    @Bindable var store: StateStore
    @AppStorage("hideWhenEmpty") private var hideWhenEmpty = false
    let contentTopPadding: CGFloat
    let notchWidth: CGFloat

    var body: some View {
        let summaries = ToolSummary.active(in: store.sessions)
        let shouldHide = summaries.isEmpty && hideWhenEmpty
        let wingWidth = NotchLayout.wingWidth(activeToolCount: summaries.count)
        let silhouetteWidth = notchWidth + wingWidth

        ZStack(alignment: .topTrailing) {
            if !shouldHide {
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 12,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                .fill(.black)
                .frame(width: silhouetteWidth)
                .frame(maxHeight: .infinity)

                HStack(spacing: 0) {
                    wingContent(summaries: summaries)
                        .frame(width: wingWidth, height: 24)
                    Color.clear
                        .frame(width: notchWidth, height: 24)
                }
                .frame(width: silhouetteWidth)
                .padding(.top, contentTopPadding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .contextMenu {
            SettingsLink {
                Label("AgentGlance Settings", systemImage: "gearshape")
            }
        }
    }

    @ViewBuilder
    private func wingContent(summaries: [ToolSummary]) -> some View {
        if summaries.isEmpty {
            Circle()
                .fill(.white.opacity(0.5))
                .frame(width: 7, height: 7)
        } else {
            HStack(spacing: 6) {
                ForEach(summaries, id: \.tool) { summary in
                    ToolIndicator(
                        summary: summary,
                        sessions: store.sessions(for: summary.tool)
                    )
                }
            }
            .padding(.horizontal, 10)
        }
    }
}

private struct ToolIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let summary: ToolSummary
    let sessions: [AgentSession]
    @State private var attentionIsBright = false
    @State private var showsSessions = false

    var body: some View {
        Button {
            showsSessions.toggle()
        } label: {
            HStack(spacing: 5) {
                ToolGlyph(tool: summary.tool)
                if summary.sessionCount > 0 {
                    Text(summary.sessionCount, format: .number)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }
                if summary.needsAttention {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.orange)
                        .opacity(reduceMotion ? 1 : (attentionIsBright ? 1 : 0.42))
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .popover(isPresented: $showsSessions, arrowEdge: .top) {
            SessionListView(
                tool: summary.tool,
                sessions: sessions,
                dismiss: { showsSessions = false }
            )
        }
    }

    private var accessibilityLabel: String {
        let attention = summary.needsAttention ? ", needs attention" : ""
        return "\(summary.tool.rawValue), \(summary.sessionCount) sessions\(attention)"
    }
}

private struct ToolGlyph: View {
    let tool: AgentTool

    var body: some View {
        Text(glyph)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 1))
            .accessibilityHidden(true)
    }

    private var glyph: String {
        switch tool {
        case .claude: "C"
        case .opencode: "O"
        case .codex: "X"
        }
    }
}

private struct SessionListView: View {
    let tool: AgentTool
    let sessions: [AgentSession]
    let dismiss: () -> Void
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tool.rawValue)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            if sessions.isEmpty {
                Text("No active sessions")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ForEach(sessions) { session in
                    sessionButton(session)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
            }
        }
        .padding(.vertical, 8)
        .frame(width: 252)
        .background(.ultraThinMaterial)
    }

    private func sessionButton(_ session: AgentSession) -> some View {
        Button {
            do {
                try FocusService.focus(session)
                dismiss()
            } catch {
                errorMessage = "Could not focus this terminal session."
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: statusSymbol(session.status))
                    .font(.system(size: 7))
                    .foregroundStyle(statusColor(session.status))
                Text(session.projectName)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Text(session.updatedAt, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(session.projectName), \(session.status.rawValue)")
    }

    private func statusSymbol(_ status: SessionStatus) -> String {
        status == .needsAttention ? "exclamationmark.circle.fill" : "circle.fill"
    }

    private func statusColor(_ status: SessionStatus) -> Color {
        switch status {
        case .needsAttention: .orange
        case .working: .green
        case .idle, .ended: .secondary
        }
    }
}

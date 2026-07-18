import AppKit
import Foundation

import AgentGlanceCore

/// Silences the bar semaphore for sessions the user visits on their own —
/// without going through AgentGlance's menu. When Ghostty is frontmost and a
/// waiting session exists, the observer asks Ghostty which terminal has
/// focus and acknowledges the matching session. It costs nothing while no
/// session is waiting or another app is frontmost.
@MainActor
final class FocusAcknowledgmentObserver {
    private static let ghosttyBundleIdentifier = "com.mitchellh.ghostty"

    private let store: StateStore
    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var queryInFlight = false

    init(store: StateStore) {
        self.store = store
    }

    func start() {
        stop()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFrontTerminal() }
        }
        // Tab switches inside Ghostty fire no workspace notification, so a
        // slow poll covers them; the guards below make idle ticks free.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFrontTerminal() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    private func checkFrontTerminal() {
        guard !queryInFlight,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                  == Self.ghosttyBundleIdentifier else {
            return
        }
        let waitingSessions = store.sessions.filter { session in
            (session.status == .idle || session.status == .needsAttention)
                && !store.acknowledgments.isAcknowledged(session)
                && session.terminal.termProgram == "ghostty"
                && session.terminal.ghosttyTerminalID != nil
        }
        guard !waitingSessions.isEmpty else { return }
        queryInFlight = true
        Task.detached(priority: .utility) {
            let frontTerminalID = Self.queryFrontTerminalID()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.queryInFlight = false
                guard let frontTerminalID else { return }
                for session in waitingSessions
                where session.terminal.ghosttyTerminalID == frontTerminalID {
                    self.store.acknowledge(session)
                }
            }
        }
    }

    private nonisolated static func queryFrontTerminalID() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Ghostty\" to get id of front terminal"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let identifier = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return identifier.isEmpty ? nil : identifier
    }
}

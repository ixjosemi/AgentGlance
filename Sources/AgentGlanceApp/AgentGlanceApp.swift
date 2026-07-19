import AppKit
import SwiftUI

import AgentGlanceCore

@main
struct AgentGlanceApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            AgentGlanceSettingsView(store: appDelegate.store)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: NotchPanelController?
    private(set) var store: StateStore?
    private var observationScheduler: ObservationScheduler?
    private var focusAcknowledgmentObserver: FocusAcknowledgmentObserver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard terminateBecauseAnotherInstanceRuns() == false else { return }
        NSApp.setActivationPolicy(.accessory)
        let stateDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agentglance/state", isDirectory: true)
        let repository = StateRepository(directoryURL: stateDirectory)
        // Session names live next to — never inside — the state directory:
        // the store watches that directory and decode-attempts every .json.
        let store = StateStore(
            repository: repository,
            nameOverridesFileURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".agentglance/session-names.json")
        )
        self.store = store
        do {
            // Directory events and Darwin notifications deliver state changes
            // immediately; polling is only a 30-second safety heartbeat.
            try store.startObserving(pollInterval: 30)
        } catch {
            store.stopObserving()
            NSLog("AgentGlance failed to start state observation: %@", String(describing: error))
        }
        panelController = NotchPanelController(store: store)
        panelController?.show()
        let scheduler = ObservationScheduler(repository: repository)
        observationScheduler = scheduler
        scheduler.start()
        let focusObserver = FocusAcknowledgmentObserver(store: store)
        focusAcknowledgmentObserver = focusObserver
        focusObserver.start()
    }

    /// Two live instances fight over `~/.agentglance/state`: each reaper
    /// rewrites sessions with its own view of the process table and the
    /// write ping-pong storms both apps (observed 2026-07-18 at ~100% CPU).
    /// The newest instance defers to the one already running.
    private func terminateBecauseAnotherInstanceRuns() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter {
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                    && !$0.isTerminated // a just-killed instance can linger in the list
            }
        guard let existing = others.first else { return false }
        NSLog(
            "AgentGlance: another instance (pid %d) is already running; exiting.",
            existing.processIdentifier
        )
        NSApp.terminate(nil)
        return true
    }
}

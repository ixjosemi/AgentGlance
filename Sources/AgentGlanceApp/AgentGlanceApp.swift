import AppKit
import SwiftUI

import AgentGlanceCore

@main
struct AgentGlanceApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            AgentGlanceSettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: NotchPanelController?
    private var reaperTimer: Timer?
    private var repository: StateRepository?
    private var store: StateStore?
    private var codexObservationController: CodexObservationController?

    /// Serial queue for everything that scans processes or writes session
    /// state. Keeps the main thread free for UI and serializes repository
    /// writers (reaper and Codex watcher) against each other.
    private let observationQueue = DispatchQueue(
        label: "com.agentglance.observation",
        qos: .utility
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let stateDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agentglance/state", isDirectory: true)
        let repository = StateRepository(directoryURL: stateDirectory)
        let store = StateStore(repository: repository)
        self.repository = repository
        self.store = store
        do {
            try store.startObserving()
        } catch {
            store.stopObserving()
            NSLog("AgentGlance failed to start state observation: %@", String(describing: error))
        }
        panelController = NotchPanelController(store: store)
        panelController?.show()
        codexObservationController = CodexObservationController(
            repository: repository,
            workQueue: observationQueue
        )
        codexObservationController?.start()
        reaperTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapDeadSessions() }
        }
    }

    /// Runs the reaper off the main thread. No explicit store reload is
    /// needed: the reaper only communicates through state files, and the
    /// store's directory observation picks those changes up on the main
    /// thread through its canonical reload path.
    private func reapDeadSessions() {
        guard let repository else { return }
        observationQueue.async {
            do {
                _ = try ReaperService(repository: repository).reap()
            } catch {
                NSLog("AgentGlance reaper failed: %@", String(describing: error))
            }
        }
    }
}

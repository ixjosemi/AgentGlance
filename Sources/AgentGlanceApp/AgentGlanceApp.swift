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
        codexObservationController = CodexObservationController(repository: repository)
        codexObservationController?.start()
        reaperTimer = Timer.scheduledTimer(
            timeInterval: 10,
            target: self,
            selector: #selector(reapDeadSessions),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func reapDeadSessions() {
        guard let repository, let store else { return }
        do {
            _ = try ReaperService(repository: repository).reap()
            try store.reload()
        } catch {
            NSLog("AgentGlance reaper failed: %@", String(describing: error))
        }
    }
}

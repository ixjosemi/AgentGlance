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
    private var store: StateStore?
    private var observationScheduler: ObservationScheduler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let stateDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agentglance/state", isDirectory: true)
        let repository = StateRepository(directoryURL: stateDirectory)
        let store = StateStore(repository: repository)
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
    }
}

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
    private var instanceLock: SingleInstanceLock?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let stateDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agentglance/state", isDirectory: true)
        let repository = StateRepository(directoryURL: stateDirectory)
        // Two live instances fight over state and stack duplicate panels.
        // The file lock is atomic across bundled and `swift run` launches;
        // unlike an NSRunningApplication preflight, simultaneous starts
        // cannot both decide that the other process should exit.
        do {
            try repository.prepareDirectory()
            guard let lock = try SingleInstanceLock.acquire(
                at: stateDirectory.appendingPathComponent(".app.lock")
            ) else {
                NSLog("AgentGlance: another instance owns the application lock; exiting.")
                NSApp.terminate(nil)
                return
            }
            instanceLock = lock
        } catch {
            NSLog("AgentGlance failed to acquire its application lock: %@", String(describing: error))
            NSApp.terminate(nil)
            return
        }
        let scheduler = ObservationScheduler(repository: repository)
        observationScheduler = scheduler
        do {
            try scheduler.performInitialReconciliation()
        } catch {
            NSLog("AgentGlance initial process reconciliation failed: %@", String(describing: error))
        }
        // Session names live next to — never inside — the state directory:
        // the store watches that directory and decode-attempts every .json.
        let store = StateStore(
            repository: repository,
            nameOverridesFileURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".agentglance/session-names.json")
        )
        self.store = store
        // Two-sound language: the system alert (user-configured sound and
        // volume) means "a session needs you"; the soft Tink means "the
        // agent finished its turn — the conversation is yours".
        UserDefaults.standard.register(defaults: [
            "attentionSoundEnabled": true,
            "turnCompleteSoundEnabled": true,
            "screenSelectionMode": ScreenSelectionMode.pointer.rawValue,
        ])
        store.onAttentionRaised = { _ in
            guard UserDefaults.standard.bool(forKey: "attentionSoundEnabled") else { return }
            NSSound.beep()
        }
        store.onTurnCompleted = { _ in
            guard UserDefaults.standard.bool(forKey: "turnCompleteSoundEnabled") else { return }
            NSSound(named: "Tink")?.play()
        }
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
        scheduler.start()
        let focusObserver = FocusAcknowledgmentObserver(store: store)
        focusAcknowledgmentObserver = focusObserver
        focusObserver.start()
    }

}

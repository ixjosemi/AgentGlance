import ServiceManagement
import SwiftUI

import AgentGlanceCore

struct AgentGlanceSettingsView: View {
    let store: StateStore?
    @AppStorage("hideWhenEmpty") private var hideWhenEmpty = false
    @AppStorage("attentionSoundEnabled") private var attentionSoundEnabled = true
    @AppStorage("turnCompleteSoundEnabled") private var turnCompleteSoundEnabled = true
    @AppStorage("screenSelectionMode") private var screenSelectionMode = ScreenSelectionMode.pointer.rawValue
    @State private var loginItemEnabled = SMAppService.mainApp.status == .enabled
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch AgentGlance at login", isOn: Binding(
                    get: { loginItemEnabled },
                    set: updateLoginItem
                ))
                Toggle("Hide when no sessions are active", isOn: $hideWhenEmpty)
                Toggle("Play the alert sound when a session needs you", isOn: $attentionSoundEnabled)
                Toggle("Play a soft sound when a session finishes its turn", isOn: $turnCompleteSoundEnabled)
                Picker("Show the notch on", selection: $screenSelectionMode) {
                    Text("Screen with pointer").tag(ScreenSelectionMode.pointer.rawValue)
                    Text("Screen with focused window").tag(ScreenSelectionMode.focusedWindow.rawValue)
                }
            }
            Section {
                Button("Reset custom session names") {
                    store?.clearAllSessionNames()
                }
                .disabled(store == nil)
            } footer: {
                Text("Sessions renamed from the notch menu go back to their live tab titles.")
            }
            Section {
                LabeledContent("Version", value: Self.versionText)
                Button("Quit AgentGlance") {
                    NSApp.terminate(nil)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
    }

    /// `swift run` executes outside the app bundle, where no Info.plist
    /// version exists — label those builds instead of hiding the row.
    private static var versionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemEnabled = enabled
            errorMessage = nil
        } catch {
            loginItemEnabled = SMAppService.mainApp.status == .enabled
            errorMessage = "Could not update the login item."
        }
    }
}

import ServiceManagement
import SwiftUI

import AgentGlanceCore

struct AgentGlanceSettingsView: View {
    let store: StateStore?
    @AppStorage("hideWhenEmpty") private var hideWhenEmpty = false
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
        .frame(width: 390)
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

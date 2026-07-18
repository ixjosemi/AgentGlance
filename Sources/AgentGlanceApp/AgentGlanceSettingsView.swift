import ServiceManagement
import SwiftUI

struct AgentGlanceSettingsView: View {
    @AppStorage("hideWhenEmpty") private var hideWhenEmpty = false
    @State private var loginItemEnabled = SMAppService.mainApp.status == .enabled
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Toggle("Hide when no sessions are active", isOn: $hideWhenEmpty)
            Toggle("Launch AgentGlance at login", isOn: Binding(
                get: { loginItemEnabled },
                set: updateLoginItem
            ))
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 390)
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

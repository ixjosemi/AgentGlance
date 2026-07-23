import ServiceManagement
import SwiftUI

import AgentGlanceCore

struct AgentGlanceSettingsView: View {
    let store: StateStore?
    @AppStorage("hideWhenEmpty") private var hideWhenEmpty = false
    @AppStorage("attentionSoundEnabled") private var attentionSoundEnabled = true
    @AppStorage("turnCompleteSoundEnabled") private var turnCompleteSoundEnabled = true
    @AppStorage("screenSelectionMode") private var screenSelectionMode = ScreenSelectionMode.pointer.rawValue
    @AppStorage("glassFrostRadius") private var glassFrostRadius = NotchGlassStyle.defaultFrostRadius
    @AppStorage("glassTintOpacity") private var glassTintOpacity = NotchGlassStyle.defaultTintOpacity
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
                Picker("Show the notch on", selection: $screenSelectionMode) {
                    Text("Screen with pointer").tag(ScreenSelectionMode.pointer.rawValue)
                    Text("Screen with focused window").tag(ScreenSelectionMode.focusedWindow.rawValue)
                    Text("All displays").tag(ScreenSelectionMode.allDisplays.rawValue)
                }
            } header: {
                Text("General")
            } footer: {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section("Sounds") {
                Toggle("Play the alert sound when a session needs you", isOn: $attentionSoundEnabled)
                Toggle("Play a soft sound when a session finishes its turn", isOn: $turnCompleteSoundEnabled)
            }

            Section {
                Slider(
                    value: $glassFrostRadius,
                    in: NotchGlassStyle.frostRadiusRange
                ) {
                    Text("Frosted")
                } minimumValueLabel: {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear glass")
                } maximumValueLabel: {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Frosted glass")
                }
                Slider(
                    value: $glassTintOpacity,
                    in: NotchGlassStyle.tintOpacityRange
                ) {
                    Text("Tint")
                } minimumValueLabel: {
                    Image(systemName: "sun.max")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Transparent tint")
                } maximumValueLabel: {
                    Image(systemName: "moon.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Dark tint")
                }
                if hasCustomAppearance {
                    Button("Reset to default appearance") {
                        glassFrostRadius = NotchGlassStyle.defaultFrostRadius
                        glassTintOpacity = NotchGlassStyle.defaultTintOpacity
                    }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Frosted diffuses what shows through the glass; Tint darkens its base. The band beside the camera always stays black.")
            }

            Section {
                Button("Reset custom session names") {
                    store?.clearAllSessionNames()
                }
                .disabled(store == nil)
            } header: {
                Text("Sessions")
            } footer: {
                Text("Sessions renamed from the notch menu go back to their live tab titles.")
            }

            Section("About") {
                LabeledContent("Version", value: Self.versionText)
                Button("Quit AgentGlance") {
                    NSApp.terminate(nil)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }

    private var hasCustomAppearance: Bool {
        glassFrostRadius != NotchGlassStyle.defaultFrostRadius
            || glassTintOpacity != NotchGlassStyle.defaultTintOpacity
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

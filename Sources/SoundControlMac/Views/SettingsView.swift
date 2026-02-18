import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppStateStore

    var body: some View {
        Form {
            Section("Profiles") {
                Toggle(
                    "Remember previous volume selection for each app",
                    isOn: Binding(
                        get: { appState.settings.rememberPerAppSelection },
                        set: { appState.setRememberPerAppSelection($0) }
                    )
                )

                Text("When disabled, selections are session-only and are not restored on next launch.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Button("Reset remembered app profiles") {
                    appState.resetRememberedProfiles()
                }
                .disabled(!appState.settings.rememberPerAppSelection)
            }
        }
    }
}

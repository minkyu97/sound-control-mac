import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppStateStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 12) {
            header
            globalDeviceControls
            Divider()
            sessionsList
            Divider()
            footerActions
        }
        .padding(12)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sound Control")
                    .font(.system(size: 16, weight: .bold))
                Text("Per-app volume control")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") {
                appState.refresh()
            }
            .buttonStyle(.borderless)
        }
    }

    private var globalDeviceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Global audio devices")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker("Output", selection: Binding(
                get: { appState.defaultOutputUID ?? "" },
                set: { uid in
                    guard !uid.isEmpty else { return }
                    appState.setDefaultOutputDevice(uid: uid)
                }
            )) {
                ForEach(appState.outputDevices) { device in
                    Text(device.name).tag(device.uid)
                }
            }

            Picker("Input", selection: Binding(
                get: { appState.defaultInputUID ?? "" },
                set: { uid in
                    guard !uid.isEmpty else { return }
                    appState.setDefaultInputDevice(uid: uid)
                }
            )) {
                ForEach(appState.inputDevices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
        }
    }

    private var sessionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Running applications")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if appState.sessions.isEmpty {
                Text("No running apps available")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(appState.sessions) { session in
                            AppSessionRowView(
                                session: session,
                                profile: appState.profile(for: session),
                                onVolumeChange: { value in
                                    appState.updateVolume(for: session, volume: value)
                                },
                                onMuteToggle: {
                                    appState.toggleMute(for: session)
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
    }

    private var footerActions: some View {
        HStack {
            Button("Settings") {
                openSettings()
            }
            .buttonStyle(.borderless)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
    }
}

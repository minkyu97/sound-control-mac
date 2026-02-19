import AppKit
import SwiftUI

struct MenuBarView: View {
    private enum GlobalTab: String, CaseIterable {
        case output = "Output"
        case input = "Input"
    }

    @EnvironmentObject private var appState: AppStateStore
    @Environment(\.openSettings) private var openSettings

    @State private var selectedGlobalTab: GlobalTab = .output

    var body: some View {
        VStack(spacing: 12) {
            header
            globalControls
            Divider()
            appsList
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

    private var globalControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GLOBAL")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker("Global Tab", selection: $selectedGlobalTab) {
                ForEach(GlobalTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            if activeGlobalDevices.isEmpty {
                Text("No audio devices found")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 4) {
                    ForEach(activeGlobalDevices) { device in
                        globalDeviceRow(device)
                    }
                }
            }
        }
    }

    private var activeGlobalDevices: [AudioDevice] {
        switch selectedGlobalTab {
        case .output:
            return appState.outputDevices
        case .input:
            return appState.inputDevices
        }
    }

    private var selectedGlobalUID: String? {
        switch selectedGlobalTab {
        case .output:
            return appState.defaultOutputUID
        case .input:
            return appState.defaultInputUID
        }
    }

    private func globalDeviceRow(_ device: AudioDevice) -> some View {
        HStack(spacing: 8) {
            Button(action: {
                selectGlobalDevice(device)
            }) {
                Image(systemName: selectedGlobalUID == device.uid ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .frame(width: 18, height: 18)

            AudioDeviceIconView(device: device)
                .frame(width: 18, height: 18)

            Text(device.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)

            Slider(
                value: Binding(
                    get: { device.volume ?? 0 },
                    set: { newValue in
                        appState.setGlobalDeviceVolume(uid: device.uid, kind: device.kind, volume: newValue)
                    }
                ),
                in: 0...1
            )
            .disabled(device.volume == nil)
            .frame(maxWidth: .infinity)

            Text(device.volume.map { "\(Int($0 * 100))%" } ?? "N/A")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(device.volume == nil ? .tertiary : .secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private func selectGlobalDevice(_ device: AudioDevice) {
        switch selectedGlobalTab {
        case .output:
            appState.setDefaultOutputDevice(uid: device.uid)
        case .input:
            appState.setDefaultInputDevice(uid: device.uid)
        }
    }

    private var appsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("APPS")
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
                                },
                                onEQBandChange: { bandIndex, gainDB in
                                    appState.updateEQBand(for: session, bandIndex: bandIndex, gainDB: gainDB)
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
                openSettingsWindow()
            }
            .buttonStyle(.borderless)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
    }

    private func openSettingsWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openSettings()

        // openSettings can occasionally no-op from menu bar context; fall back to AppKit settings actions.
        DispatchQueue.main.async {
            let showSettingsSelector = Selector(("showSettingsWindow:"))
            let showPreferencesSelector = Selector(("showPreferencesWindow:"))

            if NSApplication.shared.target(forAction: showSettingsSelector) != nil {
                NSApplication.shared.sendAction(showSettingsSelector, to: nil, from: nil)
            } else if NSApplication.shared.target(forAction: showPreferencesSelector) != nil {
                NSApplication.shared.sendAction(showPreferencesSelector, to: nil, from: nil)
            }

            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

private struct AudioDeviceIconView: View {
    let device: AudioDevice

    var body: some View {
        Group {
            if let iconURL = device.iconURL,
               let iconImage = NSImage(contentsOf: iconURL) {
                Image(nsImage: iconImage)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSystemImage)
                    .resizable()
                    .scaledToFit()
                    .padding(2)
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var fallbackSystemImage: String {
        switch device.kind {
        case .output:
            return "speaker.wave.2.fill"
        case .input:
            return "mic.fill"
        }
    }
}

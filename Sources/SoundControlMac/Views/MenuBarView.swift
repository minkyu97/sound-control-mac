import AppKit
import SwiftUI

struct MenuBarView: View {
    private enum DeviceTab: String, CaseIterable {
        case output = "Output"
        case input = "Input"
    }

    @EnvironmentObject private var appState: AppStateStore
    @Environment(\.openSettings) private var openSettings

    @State private var selectedDeviceTab: DeviceTab = .output

    var body: some View {
        VStack(spacing: 12) {
            header
            deviceControls
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

    private var deviceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DEVICE")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker("", selection: $selectedDeviceTab) {
                ForEach(DeviceTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if activeDeviceRows.isEmpty {
                Text("No audio devices found")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 4) {
                    ForEach(activeDeviceRows) { device in
                        DeviceRowView(
                            device: device,
                            isSelected: selectedDeviceUID == device.uid,
                            showEQControls: selectedDeviceTab == .output,
                            eqSettings: appState.deviceEQ(forOutputDeviceUID: device.uid),
                            onSelect: {
                                selectDevice(device)
                            },
                            onVolumeChange: { newValue in
                                appState.setGlobalDeviceVolume(uid: device.uid, kind: device.kind, volume: newValue)
                            },
                            onEQBandChange: { bandIndex, gainDB in
                                appState.updateDeviceEQBand(
                                    forOutputDeviceUID: device.uid,
                                    bandIndex: bandIndex,
                                    gainDB: gainDB
                                )
                            }
                        )
                    }
                }
            }
        }
    }

    private var activeDeviceRows: [AudioDevice] {
        switch selectedDeviceTab {
        case .output:
            return appState.outputDevices
        case .input:
            return appState.inputDevices
        }
    }

    private var selectedDeviceUID: String? {
        switch selectedDeviceTab {
        case .output:
            return appState.defaultOutputUID
        case .input:
            return appState.defaultInputUID
        }
    }

    private func selectDevice(_ device: AudioDevice) {
        switch selectedDeviceTab {
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

private struct DeviceRowView: View {
    let device: AudioDevice
    let isSelected: Bool
    let showEQControls: Bool
    let eqSettings: AppEQSettings
    let onSelect: () -> Void
    let onVolumeChange: (Double) -> Void
    let onEQBandChange: (Int, Float) -> Void

    @State private var isEditingPercent = false
    @State private var percentDraft = ""
    @State private var baselinePercent = 0
    @FocusState private var isPercentEditorFocused: Bool
    @State private var isEQExpanded = false
    @State private var displayedVolume: Double = 0
    @State private var isSliderEditing = false
    @State private var pendingVolumeValue: Double?
    @State private var pendingVolumeTask: Task<Void, Never>?

    private let percentFieldWidth: CGFloat = 38
    private let sliderEventDelayNanos: UInt64 = 60_000_000

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: onSelect) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
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
                        get: { displayedVolume },
                        set: { newValue in
                            handleSliderValueChanged(newValue)
                        }
                    ),
                    in: 0...1,
                    onEditingChanged: handleSliderEditingChanged
                )
                .disabled(device.volume == nil)
                .frame(maxWidth: .infinity)

                percentEditor

                if showEQControls {
                    Button(action: {
                        isEQExpanded.toggle()
                    }) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 20, height: 20)
                    .help("Show per-device EQ settings")
                }
            }

            if showEQControls && isEQExpanded {
                eqPanel
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .onAppear {
            syncDisplayedVolume(from: device.volume)
        }
        .onChange(of: device.volume) { _, newVolume in
            syncDisplayedVolume(from: newVolume)
        }
        .onDisappear {
            flushPendingVolume()
            commitPercentEditingIfNeededOnDisappear()
        }
    }

    private var percentEditor: some View {
        Group {
            if device.volume == nil {
                Text("N/A")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            } else if isEditingPercent {
                TextField("", text: $percentDraft)
                    .font(.system(size: 10, weight: .medium))
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                    .focused($isPercentEditorFocused)
                    .onSubmit {
                        commitPercentEditing()
                    }
                    .onExitCommand {
                        cancelPercentEditing()
                    }
                    .onChange(of: percentDraft) { _, newValue in
                        let sanitized = sanitizePercentDraft(newValue)
                        if sanitized != newValue {
                            percentDraft = sanitized
                        }
                    }
                    .onChange(of: isPercentEditorFocused) { _, focused in
                        if !focused {
                            commitPercentEditing()
                        }
                    }
            } else {
                Text("\(effectivePercent)%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        beginPercentEditing()
                    }
                    .help("Click to edit volume percentage")
            }
        }
        .frame(width: percentFieldWidth, alignment: .trailing)
    }

    private var eqPanel: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let spacing: CGFloat = 4
                let totalSpacing = spacing * CGFloat(max(0, AppEQSettings.bandCount - 1))
                let bandWidth = max(30, (geometry.size.width - totalSpacing) / CGFloat(AppEQSettings.bandCount))

                HStack(alignment: .top, spacing: spacing) {
                    ForEach(0..<AppEQSettings.bandCount, id: \.self) { index in
                        VStack(spacing: 4) {
                            Text(AppEQSettings.bandLabels[index])
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)

                            VerticalEQSlider(
                                value: Binding(
                                    get: { Double(eqSettings.gain(at: index)) },
                                    set: { newValue in
                                        onEQBandChange(index, Float(newValue))
                                    }
                                ),
                                range: Double(AppEQSettings.minGainDB)...Double(AppEQSettings.maxGainDB)
                            )
                            .frame(width: min(CGFloat(22), bandWidth), height: 86)

                            Text(eqGainText(eqSettings.gain(at: index)))
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(width: bandWidth, alignment: .top)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(height: 118)

            Text("Per-app EQ settings override this device EQ.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 2)
    }

    private var effectivePercent: Int {
        guard device.volume != nil else {
            return 0
        }
        return Int((displayedVolume * 100).rounded())
    }

    private func beginPercentEditing() {
        guard !isEditingPercent, device.volume != nil else {
            return
        }

        baselinePercent = effectivePercent
        percentDraft = "\(baselinePercent)"
        isEditingPercent = true

        DispatchQueue.main.async {
            isPercentEditorFocused = true
        }
    }

    private func commitPercentEditing() {
        guard isEditingPercent else {
            return
        }

        isEditingPercent = false
        isPercentEditorFocused = false

        guard !percentDraft.isEmpty, let parsed = Int(percentDraft) else {
            return
        }

        let clamped = min(max(parsed, 0), 100)
        let normalized = Double(clamped) / 100
        displayedVolume = normalized
        scheduleVolumeChange(normalized, immediate: true)
    }

    private func cancelPercentEditing() {
        guard isEditingPercent else {
            return
        }

        percentDraft = "\(baselinePercent)"
        isEditingPercent = false
        isPercentEditorFocused = false
    }

    private func sanitizePercentDraft(_ value: String) -> String {
        String(value.filter(\.isNumber).prefix(3))
    }

    private func eqGainText(_ gain: Float) -> String {
        let prefix = gain >= 0 ? "+" : ""
        return "\(prefix)\(gain.formatted(.number.precision(.fractionLength(1))))"
    }

    private func handleSliderValueChanged(_ newValue: Double) {
        guard device.volume != nil else {
            return
        }

        let clamped = min(max(newValue, 0), 1)
        displayedVolume = clamped
        scheduleVolumeChange(clamped)
    }

    private func handleSliderEditingChanged(_ isEditing: Bool) {
        isSliderEditing = isEditing
        if !isEditing {
            scheduleVolumeChange(displayedVolume, immediate: true)
        }
    }

    private func scheduleVolumeChange(_ value: Double, immediate: Bool = false) {
        guard device.volume != nil else {
            return
        }

        let clamped = min(max(value, 0), 1)
        pendingVolumeValue = clamped
        pendingVolumeTask?.cancel()

        if immediate {
            flushPendingVolume()
            return
        }

        pendingVolumeTask = Task {
            try? await Task.sleep(nanoseconds: sliderEventDelayNanos)
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                flushPendingVolume()
            }
        }
    }

    private func flushPendingVolume() {
        pendingVolumeTask?.cancel()
        pendingVolumeTask = nil

        guard let pendingVolumeValue else {
            return
        }

        self.pendingVolumeValue = nil
        onVolumeChange(pendingVolumeValue)
    }

    private func syncDisplayedVolume(from sourceVolume: Double?) {
        guard let sourceVolume else {
            return
        }

        guard !isSliderEditing, !isEditingPercent else {
            return
        }

        displayedVolume = min(max(sourceVolume, 0), 1)
    }

    private func commitPercentEditingIfNeededOnDisappear() {
        guard isEditingPercent else {
            return
        }
        commitPercentEditing()
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

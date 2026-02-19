import SwiftUI

struct AppSessionRowView: View {
    let session: AppSession
    let profile: AppAudioProfile
    let onVolumeChange: (Double) -> Void
    let onMuteToggle: () -> Void
    let onEQBandChange: (Int, Float) -> Void

    @State private var isEditingPercent = false
    @State private var percentDraft = ""
    @State private var baselinePercent = 0
    @FocusState private var isPercentEditorFocused: Bool
    @State private var isEQExpanded = false

    private let percentFieldWidth: CGFloat = 34

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                AppIconView(image: session.icon)

                Text(session.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .help(session.bundleIdentifier)
                    .frame(width: 110, alignment: .leading)

                Slider(value: Binding(
                    get: { profile.volume },
                    set: { value in
                        onVolumeChange(value)
                    }
                ), in: 0...1)

                Button(action: onMuteToggle) {
                    Image(systemName: profile.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .frame(width: 20, height: 20)

                percentEditor

                Button(action: {
                    isEQExpanded.toggle()
                }) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .frame(width: 20, height: 20)
                .help("Show per-app EQ settings")
            }

            if isEQExpanded {
                eqPanel
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private var eqPanel: some View {
        VStack(spacing: 6) {
            ForEach(0..<AppEQSettings.bandCount, id: \.self) { index in
                HStack(spacing: 8) {
                    Text(AppEQSettings.bandLabels[index])
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .leading)

                    Slider(
                        value: Binding(
                            get: { Double(profile.eq.gain(at: index)) },
                            set: { newValue in
                                onEQBandChange(index, Float(newValue))
                            }
                        ),
                        in: Double(AppEQSettings.minGainDB)...Double(AppEQSettings.maxGainDB)
                    )

                    Text(eqGainText(profile.eq.gain(at: index)))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 54, alignment: .trailing)
                }
            }
        }
        .padding(.top, 2)
    }

    private func eqGainText(_ gain: Float) -> String {
        let prefix = gain >= 0 ? "+" : ""
        return "\(prefix)\(gain.formatted(.number.precision(.fractionLength(1)))) dB"
    }

    private var percentEditor: some View {
        Group {
            if isEditingPercent {
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

    private var effectivePercent: Int {
        Int((profile.isMuted ? 0 : profile.volume) * 100)
    }

    private func beginPercentEditing() {
        guard !isEditingPercent else {
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
        onVolumeChange(Double(clamped) / 100)
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
}

private struct AppIconView: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(4)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

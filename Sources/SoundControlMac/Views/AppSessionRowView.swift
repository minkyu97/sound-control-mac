import SwiftUI

struct AppSessionRowView: View {
    let session: AppSession
    let profile: AppAudioProfile
    let onVolumeChange: (Double) -> Void
    let onMuteToggle: () -> Void

    @State private var isEditingPercent = false
    @State private var percentDraft = ""
    @State private var baselinePercent = 0
    @FocusState private var isPercentEditorFocused: Bool

    private let percentFieldWidth: CGFloat = 34

    var body: some View {
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
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
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

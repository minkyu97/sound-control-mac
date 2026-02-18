import SwiftUI

struct AppSessionRowView: View {
    let session: AppSession
    let profile: AppAudioProfile
    let onVolumeChange: (Double) -> Void
    let onMuteToggle: () -> Void

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

            Text("\(Int((profile.isMuted ? 0 : profile.volume) * 100))%")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
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

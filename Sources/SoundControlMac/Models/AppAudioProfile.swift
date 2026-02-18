import Foundation

struct AppAudioProfile: Codable, Hashable, Sendable {
    let bundleIdentifier: String
    var volume: Double
    var isMuted: Bool
    var preferredOutputDeviceUID: String?

    static func `default`(for bundleIdentifier: String) -> AppAudioProfile {
        AppAudioProfile(
            bundleIdentifier: bundleIdentifier,
            volume: 1.0,
            isMuted: false,
            preferredOutputDeviceUID: nil
        )
    }
}

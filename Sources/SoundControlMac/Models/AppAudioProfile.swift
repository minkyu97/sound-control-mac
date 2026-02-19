import Foundation

struct AppAudioProfile: Codable, Hashable, Sendable {
    let bundleIdentifier: String
    var volume: Double
    var isMuted: Bool
    var preferredOutputDeviceUID: String?
    var eq: AppEQSettings

    init(
        bundleIdentifier: String,
        volume: Double,
        isMuted: Bool,
        preferredOutputDeviceUID: String?,
        eq: AppEQSettings = .flat
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.volume = volume
        self.isMuted = isMuted
        self.preferredOutputDeviceUID = preferredOutputDeviceUID
        self.eq = eq
    }

    static func `default`(for bundleIdentifier: String) -> AppAudioProfile {
        AppAudioProfile(
            bundleIdentifier: bundleIdentifier,
            volume: 1.0,
            isMuted: false,
            preferredOutputDeviceUID: nil,
            eq: .flat
        )
    }

    enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case volume
        case isMuted
        case preferredOutputDeviceUID
        case eq
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        volume = try container.decode(Double.self, forKey: .volume)
        isMuted = try container.decode(Bool.self, forKey: .isMuted)
        preferredOutputDeviceUID = try container.decodeIfPresent(String.self, forKey: .preferredOutputDeviceUID)
        eq = try container.decodeIfPresent(AppEQSettings.self, forKey: .eq) ?? .flat
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(volume, forKey: .volume)
        try container.encode(isMuted, forKey: .isMuted)
        try container.encodeIfPresent(preferredOutputDeviceUID, forKey: .preferredOutputDeviceUID)
        try container.encode(eq, forKey: .eq)
    }
}

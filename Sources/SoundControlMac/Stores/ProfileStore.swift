import Foundation

@MainActor
final class ProfileStore: ObservableObject {
    private struct PersistedState: Codable {
        var settings: UserSettings
        var profiles: [String: AppAudioProfile]
    }

    @Published private(set) var settings = UserSettings()

    private(set) var persistedProfiles: [String: AppAudioProfile] = [:]
    private(set) var runtimeProfiles: [String: AppAudioProfile] = [:]

    private let stateURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(stateURL: URL? = nil) {
        if let stateURL {
            self.stateURL = stateURL
        } else {
            self.stateURL = Self.defaultStateURL()
        }
        load()
    }

    func profile(for bundleIdentifier: String) -> AppAudioProfile {
        if settings.rememberPerAppSelection {
            return persistedProfiles[bundleIdentifier] ?? .default(for: bundleIdentifier)
        }
        return runtimeProfiles[bundleIdentifier] ?? .default(for: bundleIdentifier)
    }

    func setProfile(_ profile: AppAudioProfile) {
        if settings.rememberPerAppSelection {
            persistedProfiles[profile.bundleIdentifier] = profile
            save()
            return
        }

        runtimeProfiles[profile.bundleIdentifier] = profile
    }

    func setRememberPerAppSelection(_ enabled: Bool) {
        guard settings.rememberPerAppSelection != enabled else {
            return
        }

        settings.rememberPerAppSelection = enabled

        if enabled {
            runtimeProfiles.removeAll()
        }

        save()
    }

    func resetRememberedProfiles() {
        persistedProfiles.removeAll()
        save()
    }

    private func load() {
        do {
            let data = try Data(contentsOf: stateURL)
            let state = try decoder.decode(PersistedState.self, from: data)
            settings = state.settings
            persistedProfiles = state.profiles
        } catch {
            settings = UserSettings()
            persistedProfiles = [:]
        }
    }

    private func save() {
        do {
            let directoryURL = stateURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let state = PersistedState(settings: settings, profiles: persistedProfiles)
            let data = try encoder.encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            // Persist failures are non-fatal for runtime behavior.
        }
    }

    private static func defaultStateURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("SoundControlMac", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
    }
}

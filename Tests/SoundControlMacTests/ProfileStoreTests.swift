import XCTest
@testable import SoundControlMac

@MainActor
final class ProfileStoreTests: XCTestCase {
    func testRememberedProfilePersistsAcrossStoreReload() throws {
        let tempDirectory = try makeTempDirectory()
        let stateURL = tempDirectory.appendingPathComponent("state.json")

        let store = ProfileStore(stateURL: stateURL)
        let profile = AppAudioProfile(
            bundleIdentifier: "com.example.player",
            volume: 0.25,
            isMuted: false,
            preferredOutputDeviceUID: "speaker-1"
        )

        store.setProfile(profile)

        let reloadedStore = ProfileStore(stateURL: stateURL)
        let loaded = reloadedStore.profile(for: "com.example.player")
        XCTAssertEqual(loaded.volume, 0.25, accuracy: 0.0001)
        XCTAssertEqual(loaded.preferredOutputDeviceUID, "speaker-1")
    }

    func testWhenRememberDisabledProfileStaysRuntimeOnly() throws {
        let tempDirectory = try makeTempDirectory()
        let stateURL = tempDirectory.appendingPathComponent("state.json")

        let store = ProfileStore(stateURL: stateURL)
        store.setRememberPerAppSelection(false)

        var runtimeProfile = AppAudioProfile.default(for: "com.example.player")
        runtimeProfile.volume = 0.4
        runtimeProfile.preferredOutputDeviceUID = "headset-2"
        store.setProfile(runtimeProfile)

        let reloadedStore = ProfileStore(stateURL: stateURL)
        let loaded = reloadedStore.profile(for: "com.example.player")
        XCTAssertEqual(loaded.volume, 1.0, accuracy: 0.0001)
        XCTAssertNil(loaded.preferredOutputDeviceUID)
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

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
            preferredOutputDeviceUID: "speaker-1",
            eq: AppEQSettings(gainsDB: [2.5, -1.5, 0, 3.0, -2.0])
        )

        store.setProfile(profile)

        let reloadedStore = ProfileStore(stateURL: stateURL)
        let loaded = reloadedStore.profile(for: "com.example.player")
        let expectedGains = AppEQSettings(gainsDB: [2.5, -1.5, 0, 3.0, -2.0]).gainsDB
        XCTAssertEqual(loaded.volume, 0.25, accuracy: 0.0001)
        XCTAssertEqual(loaded.preferredOutputDeviceUID, "speaker-1")
        XCTAssertEqual(loaded.eq.gainsDB, expectedGains)
    }

    func testWhenRememberDisabledProfileStaysRuntimeOnly() throws {
        let tempDirectory = try makeTempDirectory()
        let stateURL = tempDirectory.appendingPathComponent("state.json")

        let store = ProfileStore(stateURL: stateURL)
        store.setRememberPerAppSelection(false)

        var runtimeProfile = AppAudioProfile.default(for: "com.example.player")
        runtimeProfile.volume = 0.4
        runtimeProfile.preferredOutputDeviceUID = "headset-2"
        runtimeProfile.eq = AppEQSettings(gainsDB: [4, 2, 0, -2, -4])
        store.setProfile(runtimeProfile)

        let reloadedStore = ProfileStore(stateURL: stateURL)
        let loaded = reloadedStore.profile(for: "com.example.player")
        XCTAssertEqual(loaded.volume, 1.0, accuracy: 0.0001)
        XCTAssertNil(loaded.preferredOutputDeviceUID)
        XCTAssertEqual(loaded.eq, .flat)
    }

    func testLegacyStateWithoutEQDefaultsToFlat() throws {
        let tempDirectory = try makeTempDirectory()
        let stateURL = tempDirectory.appendingPathComponent("state.json")

        let legacyState = """
        {
          "settings": {
            "rememberPerAppSelection": true
          },
          "profiles": {
            "com.example.player": {
              "bundleIdentifier": "com.example.player",
              "volume": 0.42,
              "isMuted": false,
              "preferredOutputDeviceUID": "speaker-legacy"
            }
          }
        }
        """

        try legacyState.data(using: .utf8)?.write(to: stateURL)

        let store = ProfileStore(stateURL: stateURL)
        let loaded = store.profile(for: "com.example.player")

        XCTAssertEqual(loaded.volume, 0.42, accuracy: 0.0001)
        XCTAssertEqual(loaded.preferredOutputDeviceUID, "speaker-legacy")
        XCTAssertEqual(loaded.eq, .flat)
        XCTAssertEqual(store.deviceEQ(forDeviceUID: "speaker-legacy"), .flat)
    }

    func testLegacyStateWithArrayEQStillLoadsProfiles() throws {
        let tempDirectory = try makeTempDirectory()
        let stateURL = tempDirectory.appendingPathComponent("state.json")

        let legacyState = """
        {
          "settings": {
            "rememberPerAppSelection": true
          },
          "profiles": {
            "com.example.player": {
              "bundleIdentifier": "com.example.player",
              "volume": 0.66,
              "isMuted": false,
              "preferredOutputDeviceUID": "speaker-legacy",
              "eq": [2.0, -1.0, 0.5, -0.5, 3.0]
            }
          },
          "deviceEQProfiles": {
            "speaker-legacy": [1.0, 0.0, -2.0]
          }
        }
        """

        try legacyState.data(using: .utf8)?.write(to: stateURL)

        let store = ProfileStore(stateURL: stateURL)
        let loadedProfile = store.profile(for: "com.example.player")
        let loadedDeviceEQ = store.deviceEQ(forDeviceUID: "speaker-legacy")

        XCTAssertEqual(loadedProfile.volume, 0.66, accuracy: 0.0001)
        XCTAssertEqual(
            loadedProfile.eq.gainsDB,
            AppEQSettings(gainsDB: [2.0, -1.0, 0.5, -0.5, 3.0]).gainsDB
        )
        XCTAssertEqual(
            loadedDeviceEQ.gainsDB,
            AppEQSettings(gainsDB: [1.0, 0.0, -2.0]).gainsDB
        )
    }

    func testDeviceEQPersistsAcrossStoreReload() throws {
        let tempDirectory = try makeTempDirectory()
        let stateURL = tempDirectory.appendingPathComponent("state.json")

        let store = ProfileStore(stateURL: stateURL)

        var eq = AppEQSettings.flat
        eq.setGain(at: 0, gainDB: 2.5)
        eq.setGain(at: 2, gainDB: -3.0)
        eq.setGain(at: 9, gainDB: 4.5)
        store.setDeviceEQ(eq, forDeviceUID: "display-speaker-1")

        let reloadedStore = ProfileStore(stateURL: stateURL)
        let loaded = reloadedStore.deviceEQ(forDeviceUID: "display-speaker-1")

        XCTAssertEqual(loaded, eq)
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

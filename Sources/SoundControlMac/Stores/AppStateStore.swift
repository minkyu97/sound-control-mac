import Foundation

@MainActor
final class AppStateStore: ObservableObject {
    @Published private(set) var sessions: [AppSession] = []
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var defaultOutputUID: String?
    @Published private(set) var defaultInputUID: String?
    @Published private(set) var settings: UserSettings

    private let profileStore: ProfileStore
    private let deviceManager: AudioDeviceManager
    private let appMonitor: RunningAppMonitor
    private let routingService: RoutingService

    @Published private var activeProfiles: [String: AppAudioProfile] = [:]

    init(
        profileStore: ProfileStore,
        deviceManager: AudioDeviceManager,
        appMonitor: RunningAppMonitor,
        routingService: RoutingService
    ) {
        self.profileStore = profileStore
        self.deviceManager = deviceManager
        self.appMonitor = appMonitor
        self.routingService = routingService
        self.settings = profileStore.settings

        bindDeviceManager()
        bindAppMonitor()
        refresh()
    }

    convenience init() {
        self.init(
            profileStore: ProfileStore(),
            deviceManager: AudioDeviceManager(),
            appMonitor: RunningAppMonitor(),
            routingService: RoutingServiceFactory.makeDefault()
        )
    }

    func refresh() {
        appMonitor.refresh()
        deviceManager.refreshDevices()
    }

    func profile(for session: AppSession) -> AppAudioProfile {
        activeProfiles[session.bundleIdentifier] ?? .default(for: session.bundleIdentifier)
    }

    func updateVolume(for session: AppSession, volume: Double) {
        var profile = profile(for: session)
        profile.volume = min(max(volume, 0), 1)

        if profile.volume > 0 && profile.isMuted {
            profile.isMuted = false
        }

        storeAndApply(profile: profile, for: session)
    }

    func toggleMute(for session: AppSession) {
        var profile = profile(for: session)
        profile.isMuted.toggle()
        storeAndApply(profile: profile, for: session)
    }

    func updateEQBand(for session: AppSession, bandIndex: Int, gainDB: Float) {
        guard bandIndex >= 0 && bandIndex < AppEQSettings.bandCount else {
            return
        }

        var profile = profile(for: session)
        profile.eq.setGain(at: bandIndex, gainDB: gainDB)
        storeAndApply(profile: profile, for: session)
    }

    func setPreferredOutputDevice(for session: AppSession, uid: String?) {
        var profile = profile(for: session)
        profile.preferredOutputDeviceUID = uid
        storeAndApply(profile: profile, for: session)
    }

    func setDefaultOutputDevice(uid: String) {
        deviceManager.setDefaultOutputDevice(uid: uid)
    }

    func setDefaultInputDevice(uid: String) {
        deviceManager.setDefaultInputDevice(uid: uid)
    }

    func setGlobalDeviceVolume(uid: String, kind: AudioDevice.Kind, volume: Double) {
        deviceManager.setDeviceVolume(uid: uid, kind: kind, volume: volume)
    }

    func setRememberPerAppSelection(_ enabled: Bool) {
        profileStore.setRememberPerAppSelection(enabled)
        settings = profileStore.settings
        rebuildProfilesFromStore()
    }

    func resetRememberedProfiles() {
        profileStore.resetRememberedProfiles()
        rebuildProfilesFromStore()
    }

    private func bindDeviceManager() {
        deviceManager.onSnapshotChanged = { [weak self] snapshot in
            guard let self else { return }
            self.outputDevices = snapshot.outputDevices
            self.inputDevices = snapshot.inputDevices
            self.defaultOutputUID = snapshot.defaultOutputUID
            self.defaultInputUID = snapshot.defaultInputUID
            self.applyProfilesToRunningSessions()
        }
    }

    private func bindAppMonitor() {
        appMonitor.onSessionsChanged = { [weak self] sessions in
            guard let self else { return }
            self.handleSessionRefresh(sessions: sessions)
        }
    }

    private func handleSessionRefresh(sessions: [AppSession]) {
        let previousSessions = self.sessions
        let previousSessionIDs = Set(previousSessions.map(\.id))
        let nextSessionIDs = Set(sessions.map(\.id))

        self.sessions = sessions

        let terminatedIDs = previousSessionIDs.subtracting(nextSessionIDs)
        for terminatedID in terminatedIDs {
            if let session = previousSessions.first(where: { $0.id == terminatedID }) {
                routingService.clearRouting(for: session)
            }
        }

        rebuildProfilesFromStore()
        applyProfilesToRunningSessions()
    }

    private func rebuildProfilesFromStore() {
        var newProfiles: [String: AppAudioProfile] = [:]

        for session in sessions {
            let bundleID = session.bundleIdentifier
            let profile = profileStore.profile(for: bundleID)
            newProfiles[bundleID] = profile
        }

        activeProfiles = newProfiles
    }

    private func applyProfilesToRunningSessions() {
        for session in sessions {
            let profile = profile(for: session)
            if shouldRouteAudio(for: profile, bundleIdentifier: session.bundleIdentifier) {
                routingService.apply(profile: profile, to: session)
            } else {
                routingService.clearRouting(for: session)
            }
        }
    }

    private func storeAndApply(profile: AppAudioProfile, for session: AppSession) {
        activeProfiles[session.bundleIdentifier] = profile
        profileStore.setProfile(profile)

        if shouldRouteAudio(for: profile, bundleIdentifier: session.bundleIdentifier) {
            routingService.apply(profile: profile, to: session)
        } else {
            routingService.clearRouting(for: session)
        }
    }

    private func shouldRouteAudio(for profile: AppAudioProfile, bundleIdentifier: String) -> Bool {
        if profile.preferredOutputDeviceUID != nil { return true }
        if profile.isMuted { return true }
        if abs(profile.volume - 1.0) > 0.0001 { return true }
        if !profile.eq.isFlat { return true }

        // Keep route active only for non-default profiles.
        return profile != .default(for: bundleIdentifier)
    }
}

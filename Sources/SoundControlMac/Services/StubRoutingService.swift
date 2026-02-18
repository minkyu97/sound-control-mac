import Foundation
import OSLog

final class StubRoutingService: RoutingService {
    private let logger = Logger(subsystem: "com.soundcontrol.mac", category: "routing")

    func apply(profile: AppAudioProfile, to session: AppSession) {
        let outputUID = profile.preferredOutputDeviceUID ?? "system-default"
        logger.debug(
            "Apply profile bundle=\(profile.bundleIdentifier, privacy: .public) pid=\(session.pid, privacy: .public) volume=\(profile.volume, privacy: .public) muted=\(profile.isMuted, privacy: .public) output=\(outputUID, privacy: .public)"
        )
    }

    func clearRouting(for session: AppSession) {
        logger.debug("Clear profile pid=\(session.pid, privacy: .public)")
    }
}

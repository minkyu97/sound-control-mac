import Foundation

protocol RoutingService {
    func apply(profile: AppAudioProfile, to session: AppSession)
    func clearRouting(for session: AppSession)
}

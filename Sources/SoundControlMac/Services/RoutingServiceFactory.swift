import Foundation

enum RoutingServiceFactory {
    static func makeDefault() -> RoutingService {
        if #available(macOS 14.2, *) {
            return CoreAudioTapRoutingService()
        }

        return StubRoutingService()
    }
}

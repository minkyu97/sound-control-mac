import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    enum Kind: String, Codable, Hashable {
        case input
        case output
    }

    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    let kind: Kind

    var id: String { uid }
}

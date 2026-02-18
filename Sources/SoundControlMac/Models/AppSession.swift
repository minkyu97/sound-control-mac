import AppKit
import Foundation

struct AppSession: Identifiable {
    let pid: pid_t
    let memberProcessIDs: [pid_t]
    let bundleIdentifier: String
    let displayName: String
    let icon: NSImage?

    var id: String {
        bundleIdentifier
    }
}

import AppKit
import SwiftUI

@main
struct SoundControlMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppStateStore()

    var body: some Scene {
        MenuBarExtra("Sound Control", systemImage: "slider.horizontal.3") {
            MenuBarView()
                .environmentObject(appState)
                .frame(minWidth: 560, minHeight: 520)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .padding(16)
                .frame(width: 440)
        }
    }
}

import AppKit
import Foundation

@MainActor
final class RunningAppMonitor {
    private struct RegularAppContext {
        let canonicalBundleID: String
        let displayName: String
        let bundlePath: String?
    }

    private struct AppGroup {
        var canonicalBundleID: String
        var displayName: String
        var icon: NSImage?
        var primaryPID: pid_t
        var memberPIDs: Set<pid_t>
    }

    var onSessionsChanged: (([AppSession]) -> Void)?

    private var observers: [NSObjectProtocol] = []

    init() {
        registerObservers()
        refresh()
    }

    func refresh() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let runningApps = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != currentPID }

        var merged: [String: AppGroup] = [:]
        var regularContexts: [RegularAppContext] = []

        // First pass: build visible groups from regular apps only.
        for app in runningApps where app.activationPolicy == .regular {
            guard let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty else { continue }

            let rawName = app.localizedName ?? bundleIdentifier
            let canonicalBundleID = canonicalBundleIdentifier(from: bundleIdentifier)
            let name = normalizedName(rawName)

            if merged[canonicalBundleID] == nil {
                merged[canonicalBundleID] = AppGroup(
                    canonicalBundleID: canonicalBundleID,
                    displayName: name,
                    icon: app.icon,
                    primaryPID: app.processIdentifier,
                    memberPIDs: []
                )
            }

            regularContexts.append(
                RegularAppContext(
                    canonicalBundleID: canonicalBundleID,
                    displayName: name.lowercased(),
                    bundlePath: app.bundleURL?.path
                )
            )
        }

        // Second pass: attach related helper/renderer PIDs to the regular app groups.
        for app in runningApps {
            guard let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty else { continue }
            guard let targetBundleID = targetGroupKey(for: app, bundleIdentifier: bundleIdentifier, regularContexts: regularContexts) else {
                continue
            }
            guard var group = merged[targetBundleID] else {
                continue
            }

            group.memberPIDs.insert(app.processIdentifier)
            if group.icon == nil, let icon = app.icon {
                group.icon = icon
            }
            merged[targetBundleID] = group
        }

        let sessions = merged.values
            .map { group in
                let sortedPIDs = group.memberPIDs.sorted()
                return AppSession(
                    pid: group.primaryPID,
                    memberProcessIDs: sortedPIDs,
                    bundleIdentifier: group.canonicalBundleID,
                    displayName: group.displayName,
                    icon: group.icon
                )
            }
            .sorted { (lhs: AppSession, rhs: AppSession) in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }

        onSessionsChanged?(sessions)
    }

    private func registerObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]

        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
            observers.append(observer)
        }
    }

    private func canonicalBundleIdentifier(from bundleIdentifier: String) -> String {
        let suffixes = [
            ".helper", ".Helper", ".renderer", ".Renderer",
            ".gpu", ".GPU", ".webcontent", ".WebContent"
        ]

        for suffix in suffixes where bundleIdentifier.hasSuffix(suffix) {
            return String(bundleIdentifier.dropLast(suffix.count))
        }

        return bundleIdentifier
    }

    private func normalizedName(_ name: String) -> String {
        let suffixes = [
            " Web Content", " Helper", " Networking", " SearchApp",
            " Sidebar", " EventCard", " Calendar", " Aomhost"
        ]

        for suffix in suffixes where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }

        return name
    }

    private func targetGroupKey(
        for app: NSRunningApplication,
        bundleIdentifier: String,
        regularContexts: [RegularAppContext]
    ) -> String? {
        let canonicalBundleID = canonicalBundleIdentifier(from: bundleIdentifier)
        let isRegular = app.activationPolicy == .regular

        if isRegular {
            return canonicalBundleID
        }

        if regularContexts.contains(where: { $0.canonicalBundleID == canonicalBundleID }) {
            return canonicalBundleID
        }

        if let bundlePath = app.bundleURL?.path {
            if let pathMatch = regularContexts.first(where: { context in
                guard let rootPath = context.bundlePath else { return false }
                return bundlePath == rootPath || bundlePath.hasPrefix(rootPath + "/")
            }) {
                return pathMatch.canonicalBundleID
            }
        }

        let helperName = normalizedName(app.localizedName ?? bundleIdentifier).lowercased()
        if let nameMatch = regularContexts.first(where: { helperName.hasPrefix($0.displayName) || $0.displayName.hasPrefix(helperName) }) {
            return nameMatch.canonicalBundleID
        }

        return nil
    }

    private func isAuxiliaryProcess(name: String, bundleIdentifier: String) -> Bool {
        let lowerName = name.lowercased()
        let lowerBundleID = bundleIdentifier.lowercased()

        if lowerName.contains(" web content") { return true }
        if lowerName.contains(" helper") { return true }
        if lowerName.contains(" renderer") { return true }
        if lowerName.contains(" networking") { return true }
        if lowerName.contains(" searchapp") { return true }
        if lowerName.contains(" sidebar") { return true }
        if lowerName.contains(" eventcard") { return true }
        if lowerName.contains(" aomhost") { return true }

        if lowerBundleID.hasSuffix(".helper") { return true }
        if lowerBundleID.hasSuffix(".renderer") { return true }
        if lowerBundleID.hasSuffix(".gpu") { return true }
        if lowerBundleID.hasSuffix(".webcontent") { return true }

        return false
    }
}

import CoreAudio
import Foundation
import IOKit
import IOKit.graphics
import os

protocol DDCControlling {
    func isDDCBacked(deviceID: AudioDeviceID, outputDeviceName: String) -> Bool
    func currentVolume(for deviceID: AudioDeviceID, outputDeviceName: String) -> Double?
    func setVolume(_ volume: Double, for deviceID: AudioDeviceID, outputDeviceName: String) -> Bool
}

final class DDCController: DDCControlling {
    private struct CoreAudioOutputDevice {
        let id: AudioDeviceID
        let name: String
        let transport: UInt32
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SoundControlMac", category: "DDCController")
    private let discoveryCacheInterval: TimeInterval = 4.0

    private var lastDiscovery = Date.distantPast
    private var servicesByDeviceID: [AudioDeviceID: DDCService] = [:]

    func isDDCBacked(deviceID: AudioDeviceID, outputDeviceName: String) -> Bool {
        probeIfNeeded()
        return servicesByDeviceID[deviceID] != nil
    }

    func currentVolume(for deviceID: AudioDeviceID, outputDeviceName: String) -> Double? {
        probeIfNeeded()

        guard let service = servicesByDeviceID[deviceID],
              let volume = try? service.getAudioVolume(),
              volume.max > 0 else {
            return nil
        }

        return min(max(Double(volume.current) / Double(volume.max), 0), 1)
    }

    func setVolume(_ volume: Double, for deviceID: AudioDeviceID, outputDeviceName: String) -> Bool {
        probeIfNeeded()

        guard let service = servicesByDeviceID[deviceID] else {
            return false
        }

        let clamped = min(max(volume, 0), 1)
        let target = Int((clamped * 100).rounded())

        do {
            try service.setAudioVolume(target)
            return true
        } catch {
            logger.error("DDC volume write failed for device \(deviceID): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func probeIfNeeded(force: Bool = false) {
        let now = Date()
        if !force && now.timeIntervalSince(lastDiscovery) < discoveryCacheInterval {
            return
        }

        let discovered = DDCService.discoverServices()
        guard !discovered.isEmpty else {
            logger.info("DDC probe: no DCPAVServiceProxy services discovered")
            servicesByDeviceID = [:]
            lastDiscovery = now
            return
        }
        logger.info("DDC probe: discovered \(discovered.count) candidate service(s)")

        var audioCapableDisplays: [(entry: io_service_t, service: DDCService, name: String)] = []

        for discoveredService in discovered {
            let displayName = Self.displayName(for: discoveredService.entry)
            if discoveredService.service.supportsAudioVolume() {
                audioCapableDisplays.append((entry: discoveredService.entry, service: discoveredService.service, name: displayName))
            } else {
                IOObjectRelease(discoveredService.entry)
            }
        }

        guard !audioCapableDisplays.isEmpty else {
            logger.info("DDC probe: no audio-capable displays reported VCP 0x62")
            servicesByDeviceID = [:]
            lastDiscovery = now
            return
        }
        logger.info("DDC probe: \(audioCapableDisplays.count) display(s) support VCP 0x62")

        let coreAudioOutputDevices = coreAudioOutputDevices()

        var matchedServices: [AudioDeviceID: DDCService] = [:]
        var matchedDDCIndices = Set<Int>()

        // First pass: direct/fuzzy name match.
        for output in coreAudioOutputDevices {
            for (index, ddcDisplay) in audioCapableDisplays.enumerated() where !matchedDDCIndices.contains(index) {
                if Self.namesMatch(output.name, ddcDisplay.name) {
                    matchedServices[output.id] = ddcDisplay.service
                    matchedDDCIndices.insert(index)
                    break
                }
            }
        }

        // Second pass: match by likely display transport if still unmatched.
        let displayTransports: Set<UInt32> = [
            kAudioDeviceTransportTypeHDMI,
            kAudioDeviceTransportTypeDisplayPort,
            kAudioDeviceTransportTypeThunderbolt
        ]

        let transportCandidates = coreAudioOutputDevices.filter { device in
            !matchedServices.keys.contains(device.id) && displayTransports.contains(device.transport)
        }

        var transportCandidateIndex = 0
        for (index, ddcDisplay) in audioCapableDisplays.enumerated() where !matchedDDCIndices.contains(index) {
            guard transportCandidateIndex < transportCandidates.count else { break }
            let candidate = transportCandidates[transportCandidateIndex]
            matchedServices[candidate.id] = ddcDisplay.service
            matchedDDCIndices.insert(index)
            transportCandidateIndex += 1
        }

        for entry in audioCapableDisplays.map(\.entry) {
            IOObjectRelease(entry)
        }

        servicesByDeviceID = matchedServices
        lastDiscovery = now

        if !matchedServices.isEmpty {
            let matchedDeviceIDs = matchedServices.keys.map(String.init).joined(separator: ", ")
            logger.info("DDC matched output device IDs: \(matchedDeviceIDs, privacy: .public)")
        } else {
            logger.info("DDC probe: no CoreAudio output device matched discovered displays")
        }
    }

    private func coreAudioOutputDevices() -> [CoreAudioOutputDevice] {
        var outputs: [CoreAudioOutputDevice] = []

        for deviceID in allAudioDeviceIDs() {
            guard hasStream(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput),
                  let name = stringProperty(objectID: deviceID, selector: kAudioObjectPropertyName) else {
                continue
            }

            outputs.append(
                CoreAudioOutputDevice(
                    id: deviceID,
                    name: name,
                    transport: transportType(for: deviceID)
                )
            )
        }

        return outputs
    }

    private func allAudioDeviceIDs() -> [AudioDeviceID] {
        let objectID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }

        return deviceIDs
    }

    private func hasStream(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr && dataSize > 0
    }

    private func transportType(for deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return 0
        }

        var transport: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &transport)
        return status == noErr ? transport : 0
    }

    private func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)

        let status = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: Int(dataSize)) { rawPointer in
                AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, rawPointer)
            }
        }

        guard status == noErr, let value else {
            return nil
        }

        return value as String
    }

    private static func namesMatch(_ left: String, _ right: String) -> Bool {
        let normalizedLeft = normalize(left)
        let normalizedRight = normalize(right)

        if normalizedLeft == normalizedRight {
            return true
        }

        if normalizedLeft.contains(normalizedRight) || normalizedRight.contains(normalizedLeft) {
            return true
        }

        let leftTokens = Set(normalizedLeft.split(separator: " "))
        let rightTokens = Set(normalizedRight.split(separator: " "))
        return !leftTokens.isDisjoint(with: rightTokens)
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func displayName(for entry: io_service_t) -> String {
        var current = entry
        IOObjectRetain(current)

        for _ in 0..<10 {
            if let name = displayNameFromEntry(current) {
                IOObjectRelease(current)
                return name
            }

            var parent: io_registry_entry_t = 0
            let status = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)

            guard status == kIOReturnSuccess else {
                return "External Display"
            }

            current = parent
        }

        IOObjectRelease(current)
        return "External Display"
    }

    private static func displayNameFromEntry(_ entry: io_service_t) -> String? {
        guard let info = IODisplayCreateInfoDictionary(entry, IOOptionBits(kIODisplayOnlyPreferredName))?
            .takeRetainedValue() as? [String: Any],
              let names = info[kDisplayProductName] as? [String: String] else {
            return nil
        }

        return names["en_US"] ?? names["en"] ?? names.values.first
    }
}

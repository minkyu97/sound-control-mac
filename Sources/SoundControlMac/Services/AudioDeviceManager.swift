import CoreAudio
import Foundation

@MainActor
final class AudioDeviceManager {
    struct Snapshot {
        let outputDevices: [AudioDevice]
        let inputDevices: [AudioDevice]
        let defaultOutputUID: String?
        let defaultInputUID: String?
    }

    var onSnapshotChanged: ((Snapshot) -> Void)?

    private struct ListenerToken {
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var listenerTokens: [ListenerToken] = []

    init() {
        registerSystemListeners()
        refreshDevices()
    }

    func refreshDevices() {
        let allIDs = allAudioDeviceIDs()

        var outputDevices: [AudioDevice] = []
        var inputDevices: [AudioDevice] = []

        for deviceID in allIDs {
            if hasStream(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput),
               let device = makeDevice(deviceID: deviceID, kind: .output) {
                outputDevices.append(device)
            }

            if hasStream(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput),
               let device = makeDevice(deviceID: deviceID, kind: .input) {
                inputDevices.append(device)
            }
        }

        outputDevices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        inputDevices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let defaultOutputID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let defaultInputID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)

        let snapshot = Snapshot(
            outputDevices: outputDevices,
            inputDevices: inputDevices,
            defaultOutputUID: outputDevices.first(where: { $0.deviceID == defaultOutputID })?.uid,
            defaultInputUID: inputDevices.first(where: { $0.deviceID == defaultInputID })?.uid
        )

        onSnapshotChanged?(snapshot)
    }

    func setDefaultOutputDevice(uid: String) {
        guard let deviceID = audioDeviceID(forUID: uid) else { return }
        setDefaultDevice(deviceID: deviceID, selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    func setDefaultInputDevice(uid: String) {
        guard let deviceID = audioDeviceID(forUID: uid) else { return }
        setDefaultDevice(deviceID: deviceID, selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    private func registerSystemListeners() {
        registerListener(selector: kAudioHardwarePropertyDevices)
        registerListener(selector: kAudioHardwarePropertyDefaultOutputDevice)
        registerListener(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    private func registerListener(selector: AudioObjectPropertySelector) {
        let objectID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshDevices()
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, .main, block)
        guard status == noErr else { return }

        listenerTokens.append(ListenerToken(address: address, block: block))
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

    private func makeDevice(deviceID: AudioDeviceID, kind: AudioDevice.Kind) -> AudioDevice? {
        guard let uid = stringProperty(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID),
              let name = stringProperty(objectID: deviceID, selector: kAudioObjectPropertyName) else {
            return nil
        }

        return AudioDevice(
            deviceID: deviceID,
            uid: uid,
            name: name,
            kind: kind
        )
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

    private func hasStream(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        return status == noErr && dataSize > 0
    }

    private func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID {
        let objectID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &deviceID)
        guard status == noErr else {
            return 0
        }

        return deviceID
    }

    private func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        for deviceID in allAudioDeviceIDs() {
            if stringProperty(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID) == uid {
                return deviceID
            }
        }
        return nil
    }

    private func setDefaultDevice(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) {
        let objectID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var targetDeviceID = deviceID
        let dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(objectID, &address, 0, nil, dataSize, &targetDeviceID)

        if status == noErr {
            refreshDevices()
        }
    }
}

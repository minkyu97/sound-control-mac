import AppKit
import CoreAudio
import Foundation
import OSLog

final class CoreAudioTapRoutingService: RoutingService, @unchecked Sendable {
    private struct RoutingRequest: Sendable {
        let sessionID: String
        let pid: pid_t
        let bundleIdentifier: String
        let candidatePIDs: [pid_t]
        let displayName: String
        let profile: AppAudioProfile

        var normalizedCandidatePIDs: [pid_t] {
            Array(Set(candidatePIDs)).sorted()
        }
    }

    private final class GainState: @unchecked Sendable {
        private let lock = NSLock()
        private var volume: Float
        private var muted: Bool

        init(volume: Float, muted: Bool) {
            self.volume = volume
            self.muted = muted
        }

        func update(volume: Float, muted: Bool) {
            lock.lock()
            self.volume = volume
            self.muted = muted
            lock.unlock()
        }

        func gain() -> Float {
            lock.lock()
            let effective = muted ? 0 : volume
            lock.unlock()
            return effective
        }
    }

    private struct TapSession {
        let sessionID: String
        let pid: pid_t
        let candidatePIDs: [pid_t]
        let displayName: String
        let outputUID: String
        let tapID: AudioObjectID
        let tapUID: String
        let aggregateDeviceID: AudioObjectID
        let ioProcID: AudioDeviceIOProcID
        let gainState: GainState
    }

    private let queue = DispatchQueue(label: "com.soundcontrol.mac.routing.tap", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.soundcontrol.mac", category: "core-audio-tap")

    private var sessions: [String: TapSession] = [:]
    private var unsupportedLogged = false
    private var noProcessObjectLogTime: [String: Date] = [:]
    private var noProcessObjectLogSignature: [String: String] = [:]

    func apply(profile: AppAudioProfile, to session: AppSession) {
        let request = RoutingRequest(
            sessionID: session.id,
            pid: session.pid,
            bundleIdentifier: session.bundleIdentifier,
            candidatePIDs: session.memberProcessIDs.isEmpty ? [session.pid] : session.memberProcessIDs,
            displayName: session.displayName,
            profile: profile
        )

        queue.async { [weak self] in
            self?.apply(request: request)
        }
    }

    func clearRouting(for session: AppSession) {
        let sessionID = session.id
        queue.async { [weak self] in
            self?.destroySession(sessionID: sessionID)
        }
    }

    private func apply(request: RoutingRequest) {
        guard #available(macOS 14.2, *) else {
            logUnsupportedOnce()
            return
        }

        guard let outputUID = request.profile.preferredOutputDeviceUID ?? currentDefaultOutputUID() else {
            logger.error("No output device UID available for \(request.displayName, privacy: .public)")
            return
        }

        let targetVolume = Float(max(0, min(1, request.profile.volume)))
        let targetMuted = request.profile.isMuted

        if let existing = sessions[request.sessionID] {
            if existing.outputUID != outputUID || existing.candidatePIDs != request.normalizedCandidatePIDs {
                destroySession(sessionID: request.sessionID)
            } else {
                existing.gainState.update(volume: targetVolume, muted: targetMuted)
                return
            }
        }

        do {
            let newSession = try createTapSession(
                request: request,
                outputUID: outputUID,
                volume: targetVolume,
                muted: targetMuted
            )

            sessions[request.sessionID] = newSession
            noProcessObjectLogTime.removeValue(forKey: request.sessionID)
            noProcessObjectLogSignature.removeValue(forKey: request.sessionID)
            logger.debug(
                "Tap session started app=\(request.displayName, privacy: .public) pid=\(request.pid, privacy: .public) output=\(outputUID, privacy: .public)"
            )
        } catch {
            if case TapRoutingError.processObjectNotFound(let pids) = error {
                if shouldLogNoProcessObject(sessionID: request.sessionID, pids: pids) {
                    logger.debug(
                        "No active CoreAudio process object yet for app=\(request.displayName, privacy: .public) pids=\(String(describing: pids), privacy: .public)"
                    )
                }
                return
            }

            let message: String
            if let tapError = error as? TapRoutingError {
                message = tapError.errorDescription ?? String(describing: tapError)
            } else {
                message = String(describing: error)
            }
            logger.error(
                "Failed to create tap session app=\(request.displayName, privacy: .public) pid=\(request.pid, privacy: .public): \(message, privacy: .public)"
            )
        }
    }

    @available(macOS 14.2, *)
    private func createTapSession(
        request: RoutingRequest,
        outputUID: String,
        volume: Float,
        muted: Bool
    ) throws -> TapSession {
        let processObjectIDs = resolvedProcessObjectIDs(for: request)
        guard !processObjectIDs.isEmpty else {
            throw TapRoutingError.processObjectNotFound(pids: request.normalizedCandidatePIDs)
        }

        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.name = "\(request.displayName) Tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tapID = AudioObjectID(0)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr else {
            throw TapRoutingError.osStatus("AudioHardwareCreateProcessTap", tapStatus)
        }

        guard let tapUID = tapUID(for: tapID) else {
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw TapRoutingError.propertyReadFailed("kAudioTapPropertyUID")
        }

        var aggregateDeviceID = AudioObjectID(0)
        do {
            try createAggregateDevice(tapUID: tapUID, outputUID: outputUID, outDeviceID: &aggregateDeviceID)
        } catch {
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw error
        }

        let gainState = GainState(volume: volume, muted: muted)

        var ioProcID: AudioDeviceIOProcID?
        let blockStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil) { _, inputData, _, outputData, _ in
            Self.renderAudio(inputData: inputData, outputData: outputData, gain: gainState.gain())
        }

        guard blockStatus == noErr, let ioProcID else {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw TapRoutingError.osStatus("AudioDeviceCreateIOProcIDWithBlock", blockStatus)
        }

        let startStatus = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard startStatus == noErr else {
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw TapRoutingError.osStatus("AudioDeviceStart", startStatus)
        }

        return TapSession(
            sessionID: request.sessionID,
            pid: request.pid,
            candidatePIDs: request.normalizedCandidatePIDs,
            displayName: request.displayName,
            outputUID: outputUID,
            tapID: tapID,
            tapUID: tapUID,
            aggregateDeviceID: aggregateDeviceID,
            ioProcID: ioProcID,
            gainState: gainState
        )
    }

    @available(macOS 14.2, *)
    private func createAggregateDevice(tapUID: String, outputUID: String, outDeviceID: inout AudioObjectID) throws {
        let subTap: [String: Any] = [
            cStringKey(kAudioSubTapUIDKey): tapUID,
            cStringKey(kAudioSubTapDriftCompensationKey): 1
        ]

        let subDevice: [String: Any] = [
            cStringKey(kAudioSubDeviceUIDKey): outputUID,
            cStringKey(kAudioSubDeviceDriftCompensationKey): 1
        ]

        let aggregateUID = "com.soundcontrol.mac.aggregate.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            cStringKey(kAudioAggregateDeviceNameKey): "Sound Control Aggregate",
            cStringKey(kAudioAggregateDeviceUIDKey): aggregateUID,
            cStringKey(kAudioAggregateDeviceIsPrivateKey): 1,
            cStringKey(kAudioAggregateDeviceMainSubDeviceKey): outputUID,
            cStringKey(kAudioAggregateDeviceSubDeviceListKey): [subDevice],
            cStringKey(kAudioAggregateDeviceTapListKey): [subTap],
            cStringKey(kAudioAggregateDeviceTapAutoStartKey): 1
        ]

        let status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &outDeviceID)
        guard status == noErr else {
            throw TapRoutingError.osStatus("AudioHardwareCreateAggregateDevice", status)
        }
    }

    private func destroySession(sessionID: String) {
        guard let session = sessions.removeValue(forKey: sessionID) else {
            return
        }

        noProcessObjectLogTime.removeValue(forKey: sessionID)
        noProcessObjectLogSignature.removeValue(forKey: sessionID)

        let stopStatus = AudioDeviceStop(session.aggregateDeviceID, session.ioProcID)
        if stopStatus != noErr {
            logger.error("AudioDeviceStop failed for \(session.displayName, privacy: .public): \(TapRoutingError.format(status: stopStatus), privacy: .public)")
        }

        let destroyProcStatus = AudioDeviceDestroyIOProcID(session.aggregateDeviceID, session.ioProcID)
        if destroyProcStatus != noErr {
            logger.error("AudioDeviceDestroyIOProcID failed for \(session.displayName, privacy: .public): \(TapRoutingError.format(status: destroyProcStatus), privacy: .public)")
        }

        let destroyAggregateStatus = AudioHardwareDestroyAggregateDevice(session.aggregateDeviceID)
        if destroyAggregateStatus != noErr {
            logger.error("AudioHardwareDestroyAggregateDevice failed for \(session.displayName, privacy: .public): \(TapRoutingError.format(status: destroyAggregateStatus), privacy: .public)")
        }

        if #available(macOS 14.2, *) {
            let destroyTapStatus = AudioHardwareDestroyProcessTap(session.tapID)
            if destroyTapStatus != noErr {
                logger.error("AudioHardwareDestroyProcessTap failed for \(session.displayName, privacy: .public): \(TapRoutingError.format(status: destroyTapStatus), privacy: .public)")
            }
        }

        logger.debug("Tap session destroyed app=\(session.displayName, privacy: .public) pid=\(session.pid, privacy: .public) tapUID=\(session.tapUID, privacy: .public)")
    }

    private func currentDefaultOutputUID() -> String? {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioObjectID(0)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &dataSize, &deviceID)

        guard status == noErr, deviceID != 0 else {
            return nil
        }

        return stringProperty(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private func processObjectID(for pid: pid_t) -> AudioObjectID? {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var lookupPID = pid
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = withUnsafePointer(to: &lookupPID) { pointer in
            AudioObjectGetPropertyData(
                systemObjectID,
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pointer,
                &dataSize,
                &processObjectID
            )
        }

        guard status == noErr, processObjectID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }

        return processObjectID
    }

    private func resolvedProcessObjectIDs(for request: RoutingRequest) -> [AudioObjectID] {
        var ids = Set<AudioObjectID>()

        for pid in request.normalizedCandidatePIDs {
            if let processObjectID = processObjectID(for: pid) {
                ids.insert(processObjectID)
            }
        }

        let targetBundleID = request.bundleIdentifier.lowercased()
        let targetName = request.displayName.lowercased()

        for processObjectID in allProcessObjectIDs() {
            let bundleID = processBundleIdentifier(for: processObjectID)?.lowercased()
            let pid = processPID(for: processObjectID)
            let isRunningOutput = processIsRunningOutput(for: processObjectID) ?? true

            let bundleMatch: Bool = {
                guard let bundleID else { return false }
                return bundleID == targetBundleID || bundleID.hasPrefix(targetBundleID + ".")
            }()

            let nameMatch: Bool = {
                guard let pid else { return false }
                guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
                let processName = (app.localizedName ?? "").lowercased()
                return processName == targetName || processName.hasPrefix(targetName) || targetName.hasPrefix(processName)
            }()

            if (bundleMatch || nameMatch) && isRunningOutput {
                ids.insert(processObjectID)
            }
        }

        return ids.sorted()
    }

    private func allProcessObjectIDs() -> [AudioObjectID] {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObjectID, &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &dataSize, &processIDs) == noErr else {
            return []
        }

        return processIDs
    }

    private func processPID(for processObjectID: AudioObjectID) -> pid_t? {
        uint32Property(objectID: processObjectID, selector: kAudioProcessPropertyPID).map { pid_t($0) }
    }

    private func processBundleIdentifier(for processObjectID: AudioObjectID) -> String? {
        stringProperty(objectID: processObjectID, selector: kAudioProcessPropertyBundleID)
    }

    private func processIsRunningOutput(for processObjectID: AudioObjectID) -> Bool? {
        uint32Property(objectID: processObjectID, selector: kAudioProcessPropertyIsRunningOutput).map { $0 != 0 }
    }

    @available(macOS 14.2, *)
    private func tapUID(for tapID: AudioObjectID) -> String? {
        stringProperty(objectID: tapID, selector: kAudioTapPropertyUID)
    }

    private func stringProperty(objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
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

    private func uint32Property(objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else {
            return nil
        }

        return value
    }

    private func cStringKey(_ key: UnsafePointer<CChar>) -> String {
        String(validatingCString: key) ?? ""
    }

    private func shouldLogNoProcessObject(sessionID: String, pids: [pid_t]) -> Bool {
        let now = Date()
        let signature = pids.map(String.init).joined(separator: ",")
        let previousSignature = noProcessObjectLogSignature[sessionID]
        let previousDate = noProcessObjectLogTime[sessionID]

        if previousSignature != signature {
            noProcessObjectLogSignature[sessionID] = signature
            noProcessObjectLogTime[sessionID] = now
            return true
        }

        if let previousDate, now.timeIntervalSince(previousDate) < 5 {
            return false
        }

        noProcessObjectLogTime[sessionID] = now
        return true
    }

    private func logUnsupportedOnce() {
        guard !unsupportedLogged else {
            return
        }
        unsupportedLogged = true
        logger.error("Core Audio taps require macOS 14.2+; falling back to no-op routing")
    }

    private static func renderAudio(
        inputData: UnsafePointer<AudioBufferList>?,
        outputData: UnsafeMutablePointer<AudioBufferList>?,
        gain: Float
    ) {
        guard let inputData, let outputData else { return }

        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
        let count = min(inputBuffers.count, outputBuffers.count)

        for index in 0..<count {
            let source = inputBuffers[index]
            var destination = outputBuffers[index]

            let byteCount = min(Int(source.mDataByteSize), Int(destination.mDataByteSize))
            guard byteCount > 0, let src = source.mData, let dst = destination.mData else {
                continue
            }

            if gain == 1 {
                memcpy(dst, src, byteCount)
                destination.mDataByteSize = UInt32(byteCount)
                outputBuffers[index] = destination
                continue
            }

            let sampleCount = byteCount / MemoryLayout<Float>.size
            let sourceSamples = src.assumingMemoryBound(to: Float.self)
            let destinationSamples = dst.assumingMemoryBound(to: Float.self)

            for i in 0..<sampleCount {
                destinationSamples[i] = sourceSamples[i] * gain
            }

            destination.mDataByteSize = UInt32(sampleCount * MemoryLayout<Float>.size)
            outputBuffers[index] = destination
        }
    }
}

enum TapRoutingError: LocalizedError {
    case processObjectNotFound(pids: [pid_t])
    case propertyReadFailed(String)
    case osStatus(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .processObjectNotFound(let pids):
            return "Could not map any pid in \(pids) to CoreAudio process object"
        case .propertyReadFailed(let property):
            return "Failed to read property \(property)"
        case .osStatus(let operation, let status):
            return "\(operation) failed with \(Self.format(status: status))"
        }
    }

    static func format(status: OSStatus) -> String {
        let code = UInt32(bitPattern: status)
        var chars: [UnicodeScalar] = []

        for shift in stride(from: 24, through: 0, by: -8) {
            let byte = UInt8((code >> UInt32(shift)) & 0xFF)
            if byte >= 32 && byte <= 126 {
                chars.append(UnicodeScalar(byte))
            }
        }

        if chars.count == 4 {
            return "\(status) ('\(String(String.UnicodeScalarView(chars)))')"
        }

        return "\(status)"
    }
}

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

    private final class ProcessorState: @unchecked Sendable {
        private struct BiquadCoefficients {
            let b0: Float
            let b1: Float
            let b2: Float
            let a1: Float
            let a2: Float

            static let passthrough = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
        }

        private struct BiquadState {
            var z1: Float = 0
            var z2: Float = 0
        }

        private struct ChannelState {
            var bandStates: [BiquadState]
        }

        private let lock = NSLock()
        private var volume: Float
        private var muted: Bool
        private var eqGainsDB: [Float]
        private var sampleRate: Float
        private var coefficients: [BiquadCoefficients]
        private var channelStates: [ChannelState] = []

        init(volume: Float, muted: Bool, eqGainsDB: [Float], sampleRate: Float) {
            self.volume = min(max(volume, 0), 1)
            self.muted = muted
            self.eqGainsDB = Self.normalizedGains(eqGainsDB)
            self.sampleRate = max(sampleRate, 1)
            self.coefficients = Self.makeCoefficients(gainsDB: self.eqGainsDB, sampleRate: self.sampleRate)
        }

        func update(volume: Float, muted: Bool, eqGainsDB: [Float]) {
            lock.lock()
            self.volume = min(max(volume, 0), 1)
            self.muted = muted

            let normalized = Self.normalizedGains(eqGainsDB)
            if normalized != self.eqGainsDB {
                self.eqGainsDB = normalized
                self.coefficients = Self.makeCoefficients(gainsDB: normalized, sampleRate: sampleRate)
                resetFilterState()
            }
            lock.unlock()
        }

        func process(inputData: UnsafePointer<AudioBufferList>, outputData: UnsafeMutablePointer<AudioBufferList>) {
            lock.lock()
            defer { lock.unlock() }

            let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
            let count = min(inputBuffers.count, outputBuffers.count)

            let effectiveGain = muted ? 0 : volume
            let eqIsFlat = eqGainsDB.allSatisfy { abs($0) < 0.0001 }

            var globalChannelBase = 0

            for index in 0..<count {
                let source = inputBuffers[index]
                var destination = outputBuffers[index]

                let byteCount = min(Int(source.mDataByteSize), Int(destination.mDataByteSize))
                guard byteCount > 0, let src = source.mData, let dst = destination.mData else {
                    globalChannelBase += max(1, Int(source.mNumberChannels))
                    continue
                }

                let channelsInBuffer = max(1, Int(source.mNumberChannels))
                let scalarCount = byteCount / MemoryLayout<Float>.size
                let frameCount = scalarCount / channelsInBuffer
                let sampleCount = frameCount * channelsInBuffer

                guard sampleCount > 0 else {
                    destination.mDataByteSize = 0
                    outputBuffers[index] = destination
                    globalChannelBase += channelsInBuffer
                    continue
                }

                ensureChannelCapacity(globalChannelBase + channelsInBuffer)

                if eqIsFlat && effectiveGain == 1 {
                    memcpy(dst, src, sampleCount * MemoryLayout<Float>.size)
                    destination.mDataByteSize = UInt32(sampleCount * MemoryLayout<Float>.size)
                    outputBuffers[index] = destination
                    globalChannelBase += channelsInBuffer
                    continue
                }

                let sourceSamples = src.assumingMemoryBound(to: Float.self)
                let destinationSamples = dst.assumingMemoryBound(to: Float.self)

                for frameIndex in 0..<frameCount {
                    for channelIndex in 0..<channelsInBuffer {
                        let sampleIndex = frameIndex * channelsInBuffer + channelIndex
                        var sample = sourceSamples[sampleIndex]

                        if !eqIsFlat {
                            sample = applyEQ(sample: sample, channelIndex: globalChannelBase + channelIndex)
                        }

                        sample *= effectiveGain
                        destinationSamples[sampleIndex] = min(max(sample, -1), 1)
                    }
                }

                destination.mDataByteSize = UInt32(sampleCount * MemoryLayout<Float>.size)
                outputBuffers[index] = destination
                globalChannelBase += channelsInBuffer
            }
        }

        private func ensureChannelCapacity(_ count: Int) {
            while channelStates.count < count {
                channelStates.append(
                    ChannelState(
                        bandStates: Array(repeating: BiquadState(), count: coefficients.count)
                    )
                )
            }

            for index in channelStates.indices where channelStates[index].bandStates.count != coefficients.count {
                channelStates[index].bandStates = Array(repeating: BiquadState(), count: coefficients.count)
            }
        }

        private func resetFilterState() {
            for index in channelStates.indices {
                channelStates[index].bandStates = Array(repeating: BiquadState(), count: coefficients.count)
            }
        }

        private func applyEQ(sample: Float, channelIndex: Int) -> Float {
            var value = sample

            for bandIndex in coefficients.indices {
                let coefficients = coefficients[bandIndex]
                var state = channelStates[channelIndex].bandStates[bandIndex]

                let output = coefficients.b0 * value + state.z1
                let nextZ1 = coefficients.b1 * value - coefficients.a1 * output + state.z2
                let nextZ2 = coefficients.b2 * value - coefficients.a2 * output

                state.z1 = nextZ1
                state.z2 = nextZ2
                channelStates[channelIndex].bandStates[bandIndex] = state
                value = output
            }

            return value
        }

        private static func normalizedGains(_ gains: [Float]) -> [Float] {
            var normalized = Array(gains.prefix(AppEQSettings.bandCount))
            if normalized.count < AppEQSettings.bandCount {
                normalized.append(contentsOf: repeatElement(0, count: AppEQSettings.bandCount - normalized.count))
            }

            return normalized.map {
                min(max($0, AppEQSettings.minGainDB), AppEQSettings.maxGainDB)
            }
        }

        private static func makeCoefficients(gainsDB: [Float], sampleRate: Float) -> [BiquadCoefficients] {
            let frequencyCount = min(AppEQSettings.centerFrequencies.count, gainsDB.count)

            return (0..<frequencyCount).map { index in
                makePeakingCoefficients(
                    centerFrequency: AppEQSettings.centerFrequencies[index],
                    gainDB: gainsDB[index],
                    q: 1.0,
                    sampleRate: sampleRate
                )
            }
        }

        private static func makePeakingCoefficients(
            centerFrequency: Float,
            gainDB: Float,
            q: Float,
            sampleRate: Float
        ) -> BiquadCoefficients {
            guard abs(gainDB) > 0.0001, sampleRate > 0 else {
                return .passthrough
            }

            let nyquist = sampleRate * 0.5
            let safeFrequency = min(max(centerFrequency, 20), nyquist * 0.98)
            let omega = 2 * Float.pi * safeFrequency / sampleRate
            let alpha = sin(omega) / (2 * q)
            let amplitude = pow(10, gainDB / 40)
            let cosOmega = cos(omega)

            let b0 = 1 + alpha * amplitude
            let b1 = -2 * cosOmega
            let b2 = 1 - alpha * amplitude
            let a0 = 1 + alpha / amplitude
            let a1 = -2 * cosOmega
            let a2 = 1 - alpha / amplitude

            guard abs(a0) > 0.0000001 else {
                return .passthrough
            }

            return BiquadCoefficients(
                b0: b0 / a0,
                b1: b1 / a0,
                b2: b2 / a0,
                a1: a1 / a0,
                a2: a2 / a0
            )
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
        let processorState: ProcessorState
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
        let targetEQGains = request.profile.eq.gainsDB

        if let existing = sessions[request.sessionID] {
            if existing.outputUID != outputUID || existing.candidatePIDs != request.normalizedCandidatePIDs {
                destroySession(sessionID: request.sessionID)
            } else {
                existing.processorState.update(volume: targetVolume, muted: targetMuted, eqGainsDB: targetEQGains)
                return
            }
        }

        do {
            let newSession = try createTapSession(
                request: request,
                outputUID: outputUID,
                volume: targetVolume,
                muted: targetMuted,
                eqGainsDB: targetEQGains
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
        muted: Bool,
        eqGainsDB: [Float]
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

        let sampleRate = Float(float64Property(objectID: aggregateDeviceID, selector: kAudioDevicePropertyNominalSampleRate) ?? 48_000)

        let processorState = ProcessorState(
            volume: volume,
            muted: muted,
            eqGainsDB: eqGainsDB,
            sampleRate: sampleRate
        )

        var ioProcID: AudioDeviceIOProcID?
        let blockStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil) { _, inputData, _, outputData, _ in
            Self.renderAudio(inputData: inputData, outputData: outputData, processorState: processorState)
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
            processorState: processorState
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

    private func float64Property(objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> Float64? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: Float64 = 0
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else {
            return nil
        }

        return value
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
        processorState: ProcessorState
    ) {
        guard let inputData, let outputData else { return }
        processorState.process(inputData: inputData, outputData: outputData)
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

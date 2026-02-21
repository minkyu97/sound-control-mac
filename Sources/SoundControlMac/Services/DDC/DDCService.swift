import Darwin
import Foundation
import IOKit
import os

enum DDCError: Error {
    case apiNotAvailable
    case serviceCreationFailed
    case writeFailed(IOReturn)
    case readFailed(IOReturn)
    case checksumMismatch
    case invalidResponse
    case unsupportedVCP
}

private enum IOAVServiceLoader {
    typealias CreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias ReadI2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutablePointer<UInt8>, UInt32) -> IOReturn
    typealias WriteI2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafePointer<UInt8>, UInt32) -> IOReturn

    nonisolated(unsafe) private static var createFn: CreateWithServiceFn?
    nonisolated(unsafe) private static var readFn: ReadI2CFn?
    nonisolated(unsafe) private static var writeFn: WriteI2CFn?
    nonisolated(unsafe) private static var didLoad = false
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SoundControlMac", category: "DDCService")

    static func ensureLoaded() -> Bool {
        guard !didLoad else { return createFn != nil && readFn != nil && writeFn != nil }
        didLoad = true

        let path = "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer"
        guard let handle = dlopen(path, RTLD_NOW) else {
            if let error = dlerror() {
                logger.error("Unable to load IOMobileFramebuffer: \(String(cString: error), privacy: .public)")
            } else {
                logger.error("Unable to load IOMobileFramebuffer")
            }
            return false
        }

        guard let createSymbol = dlsym(handle, "IOAVServiceCreateWithService"),
              let readSymbol = dlsym(handle, "IOAVServiceReadI2C"),
              let writeSymbol = dlsym(handle, "IOAVServiceWriteI2C") else {
            logger.error("Unable to resolve IOAVService symbols")
            return false
        }

        createFn = unsafeBitCast(createSymbol, to: CreateWithServiceFn.self)
        readFn = unsafeBitCast(readSymbol, to: ReadI2CFn.self)
        writeFn = unsafeBitCast(writeSymbol, to: WriteI2CFn.self)
        return true
    }

    static func createService(for entry: io_service_t) -> CFTypeRef? {
        guard ensureLoaded(), let createFn else {
            return nil
        }

        return createFn(kCFAllocatorDefault, entry)?.takeRetainedValue()
    }

    static func readI2C(
        service: CFTypeRef,
        chipAddress: UInt32,
        dataAddress: UInt32,
        buffer: UnsafeMutablePointer<UInt8>,
        size: UInt32
    ) -> IOReturn {
        guard let readFn else { return kIOReturnNotReady }
        return readFn(service, chipAddress, dataAddress, buffer, size)
    }

    static func writeI2C(
        service: CFTypeRef,
        chipAddress: UInt32,
        dataAddress: UInt32,
        buffer: UnsafePointer<UInt8>,
        size: UInt32
    ) -> IOReturn {
        guard let writeFn else { return kIOReturnNotReady }
        return writeFn(service, chipAddress, dataAddress, buffer, size)
    }
}

final class DDCService: @unchecked Sendable {
    private let service: CFTypeRef

    // DDC/CI addressing.
    private let chipAddress: UInt32 = 0x37
    private let writeAddress: UInt32 = 0x51

    // Timings/retries.
    private let writeSleepTimeMicros: UInt32 = 10_000
    private let readSleepTimeMicros: UInt32 = 50_000
    private let retrySleepTimeMicros: UInt32 = 100_000
    private let writeCycles = 2
    private let retryCount = 5

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SoundControlMac", category: "DDCService")

    init(service: CFTypeRef) {
        self.service = service
    }

    func supportsAudioVolume() -> Bool {
        (try? readVCP(0x62)) != nil
    }

    func getAudioVolume() throws -> (current: Int, max: Int) {
        let result = try readVCP(0x62)
        return (current: Int(result.current), max: Int(result.max))
    }

    func setAudioVolume(_ volume: Int) throws {
        let clamped = UInt16(max(0, min(100, volume)))
        try writeVCP(0x62, value: clamped)
    }

    private func readVCP(_ code: UInt8) throws -> (current: UInt16, max: UInt16) {
        var packet: [UInt8] = [0x82, 0x01, code]
        packet.append(writeChecksum(packet))

        var lastError: DDCError = .readFailed(kIOReturnError)

        for attempt in 0..<retryCount {
            do {
                let reply = try i2cWriteRead(packet: packet)

                if reply.allSatisfy({ $0 == 0 }) {
                    throw DDCError.invalidResponse
                }

                // Monitor busy/null response.
                if reply.count >= 2, reply[0] == 0x6E, reply[1] == 0x80 {
                    lastError = .invalidResponse
                    if attempt < retryCount - 1 {
                        usleep(retrySleepTimeMicros)
                    }
                    continue
                }

                return try parseVCPResponse(reply, expectedCode: code)
            } catch let error as DDCError {
                lastError = error
                if attempt < retryCount - 1 {
                    usleep(retrySleepTimeMicros)
                }
            }
        }

        throw lastError
    }

    private func writeVCP(_ code: UInt8, value: UInt16) throws {
        var packet: [UInt8] = [0x84, 0x03, code, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        packet.append(writeChecksum(packet))

        var lastError: DDCError = .writeFailed(kIOReturnError)

        for attempt in 0..<retryCount {
            do {
                try i2cWrite(packet: packet)
                return
            } catch let error as DDCError {
                lastError = error
                if attempt < retryCount - 1 {
                    usleep(retrySleepTimeMicros)
                }
            }
        }

        throw lastError
    }

    private func i2cWriteRead(packet: [UInt8]) throws -> [UInt8] {
        var writeSucceeded = false
        var lastStatus: IOReturn = kIOReturnError

        for _ in 0..<writeCycles {
            usleep(writeSleepTimeMicros)
            let status = packet.withUnsafeBufferPointer { buffer -> IOReturn in
                guard let address = buffer.baseAddress else { return kIOReturnBadArgument }
                return IOAVServiceLoader.writeI2C(
                    service: service,
                    chipAddress: chipAddress,
                    dataAddress: writeAddress,
                    buffer: address,
                    size: UInt32(buffer.count)
                )
            }
            lastStatus = status
            if status == kIOReturnSuccess {
                writeSucceeded = true
            }
        }

        guard writeSucceeded else {
            throw DDCError.writeFailed(lastStatus)
        }

        usleep(readSleepTimeMicros)

        var reply = [UInt8](repeating: 0, count: 11)
        let readStatus = reply.withUnsafeMutableBufferPointer { buffer -> IOReturn in
            guard let address = buffer.baseAddress else { return kIOReturnBadArgument }
            return IOAVServiceLoader.readI2C(
                service: service,
                chipAddress: chipAddress,
                dataAddress: 0,
                buffer: address,
                size: UInt32(buffer.count)
            )
        }

        guard readStatus == kIOReturnSuccess else {
            throw DDCError.readFailed(readStatus)
        }

        return reply
    }

    private func i2cWrite(packet: [UInt8]) throws {
        var lastStatus: IOReturn = kIOReturnError

        for _ in 0..<writeCycles {
            usleep(writeSleepTimeMicros)
            let status = packet.withUnsafeBufferPointer { buffer -> IOReturn in
                guard let address = buffer.baseAddress else { return kIOReturnBadArgument }
                return IOAVServiceLoader.writeI2C(
                    service: service,
                    chipAddress: chipAddress,
                    dataAddress: writeAddress,
                    buffer: address,
                    size: UInt32(buffer.count)
                )
            }
            lastStatus = status
            if status == kIOReturnSuccess {
                return
            }
        }

        throw DDCError.writeFailed(lastStatus)
    }

    private func writeChecksum(_ data: [UInt8]) -> UInt8 {
        var checksum = UInt8(truncatingIfNeeded: (chipAddress << 1) ^ writeAddress)
        for byte in data {
            checksum ^= byte
        }
        return checksum
    }

    private func responseChecksum(_ data: [UInt8]) -> UInt8 {
        var checksum: UInt8 = 0x50
        for byte in data {
            checksum ^= byte
        }
        return checksum
    }

    private func parseVCPResponse(_ reply: [UInt8], expectedCode: UInt8) throws -> (current: UInt16, max: UInt16) {
        guard reply.count >= 11 else {
            throw DDCError.invalidResponse
        }

        let expectedChecksum = responseChecksum(Array(reply[0..<10]))
        guard reply[10] == expectedChecksum else {
            throw DDCError.checksumMismatch
        }

        guard reply[3] == 0 else {
            throw DDCError.unsupportedVCP
        }

        guard reply[4] == expectedCode else {
            throw DDCError.invalidResponse
        }

        let maxValue = (UInt16(reply[6]) << 8) | UInt16(reply[7])
        let currentValue = (UInt16(reply[8]) << 8) | UInt16(reply[9])
        return (current: currentValue, max: maxValue)
    }

    static func discoverServices() -> [(entry: io_service_t, service: DDCService)] {
        guard IOAVServiceLoader.ensureLoaded() else {
            logger.error("IOAVService APIs are unavailable")
            return []
        }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("DCPAVServiceProxy"),
            &iterator
        )

        guard result == kIOReturnSuccess else {
            logger.error("IOServiceGetMatchingServices failed: \(result)")
            return []
        }

        defer { IOObjectRelease(iterator) }

        var services: [(entry: io_service_t, service: DDCService)] = []
        var entry = IOIteratorNext(iterator)

        while entry != 0 {
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if location == "Embedded" {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
                continue
            }

            if let avService = IOAVServiceLoader.createService(for: entry) {
                services.append((entry: entry, service: DDCService(service: avService)))
            } else {
                IOObjectRelease(entry)
            }

            entry = IOIteratorNext(iterator)
        }

        return services
    }
}

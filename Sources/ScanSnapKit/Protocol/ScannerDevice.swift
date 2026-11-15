import Foundation

public enum ScannerError: Error, CustomStringConvertible {
    case nak(ESCCommand)
    case unexpectedStatus(ESCCommand, UInt8)
    case shortReply(ESCCommand, expected: Int, got: Int)
    case hardware(code: UInt8)
    case firmwareFile(String)
    case firmwareDidNotBoot

    public var description: String {
        switch self {
        case let .nak(command): "Scanner rejected command \(command)."
        case let .unexpectedStatus(command, byte): String(format: "Unexpected status 0x%02X after %@.", byte, "\(command)")
        case let .shortReply(command, expected, got): "Short reply to \(command): \(got) of \(expected) bytes."
        case let .hardware(code): String(format: "Scanner reported hardware error 0x%02X.", code)
        case let .firmwareFile(reason): "Firmware file problem: \(reason)"
        case .firmwareDidNotBoot: "The scanner did not report ready after the firmware upload."
        }
    }
}

public struct HardwareInfo: Sendable {
    public let raw: [UInt8]
    public var vendor: String { Self.text(raw, 0..<8) }
    public var product: String { Self.text(raw, 8..<24) }
    public var firmwareRevision: String { Self.text(raw, 24..<28) }

    private static func text(_ raw: [UInt8], _ range: Range<Int>) -> String {
        guard raw.count >= range.upperBound else { return "" }
        return String(decoding: raw[range], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}

public struct HardwareStatus: Sendable {
    public let raw: [UInt8]
    public var hasError: Bool { raw[0] & 0x80 != 0 }
    public var errorCode: UInt8 { raw[1] }
}

public struct SensorState: Sendable, Equatable {
    public let raw: [UInt8]
    public var coverOpen: Bool { raw[0] & 0x20 != 0 }
    /// Bit 0x40 is the "feeder empty" flag (SANE `hw_hopper`, ScanSnap Manager's batch-end check);
    /// verified on hardware: clear while sheets are in the feeder.
    public var paperLoaded: Bool { raw[0] & 0x40 == 0 }
    public var paperAtTop: Bool { raw[0] & 0x80 != 0 }
    /// Verified on hardware: high for roughly 100 ms per press.
    public var scanButton: Bool { raw[1] & 0x01 != 0 }
    /// Verified on hardware: set after ~40 s idle; the next button press or paper insert wakes it.
    public var sleeping: Bool { raw[1] & 0x80 != 0 }
}

/// Command layer for the S1300/S1300i (inherits the S300 protocol).
public final class ScannerDevice {
    public let transport: USBTransport

    public init(transport: USBTransport) {
        self.transport = transport
    }

    public var model: ScanSnapModel { transport.model }

    // MARK: Framing

    private func expectACK(_ command: ESCCommand) throws {
        let reply = try transport.read(1)
        guard let status = reply.first else { throw ScannerError.shortReply(command, expected: 1, got: 0) }
        switch status {
        case 0x06: return
        case 0x15: throw ScannerError.nak(command)
        default: throw ScannerError.unexpectedStatus(command, status)
        }
    }

    /// `1B op` → ACK, then optional payload → ACK.
    public func send(_ command: ESCCommand, payload: [UInt8]? = nil) throws {
        try transport.write(command.bytes)
        try expectACK(command)
        guard let payload else { return }
        try transport.write(payload)
        try expectACK(command)
    }

    /// `1B op` → reply of up to `length` bytes (no ACK first).
    public func query(_ command: ESCCommand, length: Int, minimum: Int? = nil) throws -> [UInt8] {
        try transport.write(command.bytes)
        let reply = try transport.read(length)
        let required = minimum ?? length
        guard reply.count >= required else {
            throw ScannerError.shortReply(command, expected: required, got: reply.count)
        }
        return reply
    }

    // MARK: Queries

    public func hardwareInfo() throws -> HardwareInfo {
        HardwareInfo(raw: try query(.hardwareInfo, length: 0x60, minimum: 28))
    }

    public func hardwareStatus() throws -> HardwareStatus {
        HardwareStatus(raw: try query(.hardwareStatus, length: 2))
    }

    public func sensors() throws -> SensorState {
        SensorState(raw: try query(.sensorInfo, length: 4))
    }

    public func eeprom() throws -> [UInt8] {
        try query(.eepromRead, length: 0x100)
    }

    // MARK: Controls

    public func setPowerLED(_ on: Bool) throws { try send(.powerLED, payload: [on ? 1 : 0]) }
    public func setLamp(_ on: Bool) throws { try send(.lamp, payload: [on ? 1 : 0]) }
    public func feedPaper() throws { try send(.paper, payload: [1]) }
    public func ejectPaper() throws { try send(.paper, payload: [0]) }
    public func cancel() throws { try send(.cancel) }

    // MARK: Recovery

    /// Brings a scanner that stopped responding (interrupted mid-transfer) back to a usable state.
    /// Returns a description of what was needed; throws if the scanner still does not answer.
    @discardableResult
    public func recover() throws -> String {
        transport.clearStalls()
        let drained = transport.drain()
        let saved = transport.timeout
        transport.timeout = 2
        defer { transport.timeout = saved }
        try? send(.cancel)
        transport.drain()
        _ = try hardwareStatus()
        return drained > 0 ? "discarded \(drained) bytes of an interrupted scan" : "cleared pipes"
    }

    // MARK: Firmware

    /// Uploads a `.nal` image and boots it.
    public func uploadFirmware(_ firmware: Firmware) throws {
        var image = Array(firmware.image)
        image.append(image.reduce(0, &+))

        do {
            try send(.firmwarePrepare)
        } catch ScannerError.nak(.firmwarePrepare) {
            // The boot ROM rejects 1B 17; it is only needed when replacing running firmware.
        }
        try transport.write(ESCCommand.firmwareDownload.bytes)
        try expectACK(.firmwareDownload)
        try transport.write([0x01, 0x00, 0x01, 0x00])
        try transport.write(image)
        try expectACK(.firmwareDownload)

        for _ in 0..<10 {
            try send(.firmwareBoot, payload: [0x80])
            let status = try hardwareStatus()
            if !status.hasError { return }
            guard (0x40...0x49).contains(status.errorCode) else { throw ScannerError.hardware(code: status.errorCode) }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw ScannerError.firmwareDidNotBoot
    }
}

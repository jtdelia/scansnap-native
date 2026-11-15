import Foundation
import IOKit
import IOUSBHost

public enum ScanSnapModel: UInt16, CaseIterable, Sendable {
    case s1300 = 0x11ED
    case s1300i = 0x128D

    public static let vendorID: UInt16 = 0x04C5

    public var displayName: String {
        switch self {
        case .s1300: "ScanSnap S1300"
        case .s1300i: "ScanSnap S1300i"
        }
    }

    public var firmwarePrefix: String {
        switch self {
        case .s1300: "1300_"
        case .s1300i: "1300i_"
        }
    }
}

public enum USBTransportError: Error, CustomStringConvertible {
    case deviceNotFound
    case interfaceNotFound
    case missingBulkEndpoints
    case shortWrite(expected: Int, sent: Int)

    public var description: String {
        switch self {
        case .deviceNotFound: "No supported ScanSnap is connected."
        case .interfaceNotFound: "The scanner's USB interface did not appear after configuration."
        case .missingBulkEndpoints: "The scanner does not expose a bulk IN and bulk OUT endpoint."
        case let .shortWrite(expected, sent): "USB write sent \(sent) of \(expected) bytes."
        }
    }
}

/// Bulk-only transport to a ScanSnap S300-family scanner, matching
/// ScanSnap Manager: first bulk IN and first bulk OUT endpoint of interface 0.
public final class USBTransport {
    public let model: ScanSnapModel
    public var timeout: TimeInterval = 120
    public var trace: ((String) -> Void)?

    private let device: IOUSBHostDevice
    private let interface: IOUSBHostInterface
    private let inPipe: IOUSBHostPipe
    private let outPipe: IOUSBHostPipe

    public static func connectedModel() -> ScanSnapModel? {
        ScanSnapModel.allCases.first { matchingService(for: $0) != 0 }
    }

    public init(model: ScanSnapModel) throws {
        self.model = model
        let deviceService = Self.matchingService(for: model)
        guard deviceService != 0 else { throw USBTransportError.deviceNotFound }
        defer { IOObjectRelease(deviceService) }

        device = try IOUSBHostDevice(__ioService: deviceService, options: [], queue: nil, interestHandler: nil)
        try device.__configure(withValue: 1, matchInterfaces: true)

        interface = try Self.openInterface(model: model)
        (inPipe, outPipe) = try Self.bulkPipes(of: interface)
    }

    deinit {
        interface.destroy()
        device.destroy()
    }

    public func write(_ bytes: [UInt8]) throws {
        trace?("→ \(bytes.count) bytes \(Self.hex(bytes.prefix(16)))")
        let data = NSMutableData(bytes: bytes, length: bytes.count)
        var sent = 0
        try outPipe.__sendIORequest(with: data, bytesTransferred: &sent, completionTimeout: timeout)
        guard sent == bytes.count else { throw USBTransportError.shortWrite(expected: bytes.count, sent: sent) }
    }

    public func read(_ length: Int) throws -> [UInt8] {
        let data = NSMutableData(length: length)!
        var received = 0
        try inPipe.__sendIORequest(with: data, bytesTransferred: &received, completionTimeout: timeout)
        let bytes = [UInt8](data.prefix(received))
        trace?("← \(bytes.count) bytes \(Self.hex(bytes.prefix(16)))")
        return bytes
    }

    /// Reads up to `buffer.length` bytes into a caller-owned buffer without copying; returns the count.
    public func read(into buffer: NSMutableData) throws -> Int {
        var received = 0
        try inPipe.__sendIORequest(with: buffer, bytesTransferred: &received, completionTimeout: timeout)
        return received
    }

    public func clearStalls() {
        try? inPipe.clearStall()
        try? outPipe.clearStall()
    }

    /// Discards data still queued in the scanner (for example after the app quit mid-sheet).
    /// Returns the number of bytes thrown away.
    @discardableResult
    public func drain(maxBytes: Int = 64 << 20) -> Int {
        let saved = timeout
        timeout = 0.3
        defer { timeout = saved }
        let buffer = NSMutableData(length: 1 << 20)!
        var drained = 0
        while drained < maxBytes, let count = try? read(into: buffer), count > 0 {
            drained += count
        }
        return drained
    }

    /// USB port reset; the scanner re-enumerates and loses its uploaded firmware.
    public func resetDevice() throws {
        try device.reset()
    }

    private static func matchingService(for model: ScanSnapModel) -> io_service_t {
        let matching = IOUSBHostDevice.__createMatchingDictionary(
            withVendorID: NSNumber(value: ScanSnapModel.vendorID), productID: NSNumber(value: model.rawValue),
            bcdDevice: nil, deviceClass: nil, deviceSubclass: nil, deviceProtocol: nil,
            speed: nil, productIDArray: nil)
        return IOServiceGetMatchingService(kIOMainPortDefault, matching.takeUnretainedValue())
    }

    private static func openInterface(model: ScanSnapModel) throws -> IOUSBHostInterface {
        let matching = IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: NSNumber(value: ScanSnapModel.vendorID), productID: NSNumber(value: model.rawValue),
            bcdDevice: nil, interfaceNumber: 0, configurationValue: 1,
            interfaceClass: nil, interfaceSubclass: nil, interfaceProtocol: nil,
            speed: nil, productIDArray: nil)
        let unmanaged = matching.takeUnretainedValue()
        for _ in 0..<50 {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, unmanaged)
            if service != 0 {
                defer { IOObjectRelease(service) }
                return try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw USBTransportError.interfaceNotFound
    }

    private static func bulkPipes(of interface: IOUSBHostInterface) throws -> (IOUSBHostPipe, IOUSBHostPipe) {
        let bulkTransferType: UInt8 = 0x02
        var inAddress: UInt8?
        var outAddress: UInt8?
        let configuration = interface.configurationDescriptor
        let interfaceDescriptor = interface.interfaceDescriptor
        var current = UnsafeRawPointer(interfaceDescriptor).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        while let endpoint = IOUSBGetNextEndpointDescriptor(configuration, interfaceDescriptor, current) {
            if endpoint.pointee.bmAttributes & 0x03 == bulkTransferType {
                let address = endpoint.pointee.bEndpointAddress
                if address & 0x80 != 0 {
                    inAddress = inAddress ?? address
                } else {
                    outAddress = outAddress ?? address
                }
            }
            current = UnsafeRawPointer(endpoint).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }
        guard let inAddress, let outAddress else { throw USBTransportError.missingBulkEndpoints }
        return (try interface.copyPipe(withAddress: Int(inAddress)),
                try interface.copyPipe(withAddress: Int(outAddress)))
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

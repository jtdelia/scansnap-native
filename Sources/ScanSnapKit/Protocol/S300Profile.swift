/// Per-resolution raw geometry and window payloads for the S300/S1300.
/// Rows are generated into `S300Tables.swift`.
public struct S300Profile: Sendable {
    public let xResolution: Int
    public let yResolution: Int
    public let usbPower: Bool
    /// Scan area limits in pixels at this profile's resolution.
    public let maxX: Int, minX: Int, maxY: Int, minY: Int
    /// Raw block layout: each line holds three colour planes, each pixel 3 bytes (front, back, pad).
    public let lineStride: Int, planeStride: Int, planeWidth: Int
    /// Lines per `1B D3` block.
    public let blockHeight: Int
    public let calLineStride: Int, calPlaneStride: Int, calPlaneWidth: Int
    public let coarseCalWindow: [UInt8]
    public let fineCalWindow: [UInt8]
    public let sendCalWindow: [UInt8]
    public let sendCal1Header: [UInt8]
    public let sendCal2Header: [UInt8]
    public let scanWindow: [UInt8]

    /// Smallest profile that covers `dpi` for the given power source.
    public static func best(forDPI dpi: Int, usbPower: Bool) -> S300Profile? {
        all.filter { $0.usbPower == usbPower && $0.xResolution >= dpi && $0.yResolution >= dpi }
            .min { $0.xResolution < $1.xResolution }
    }

    /// Supported output resolutions (y resolution equals x resolution).
    public static func outputResolutions(usbPower: Bool) -> [Int] {
        all.filter { $0.usbPower == usbPower && $0.xResolution == $0.yResolution }.map(\.xResolution)
    }

    func scanWindow(lines: Int) -> [UInt8] {
        var window = scanWindow
        window.replaceSubrange(0x1A..<0x1E, with: [
            UInt8(truncatingIfNeeded: lines >> 24), UInt8(truncatingIfNeeded: lines >> 16),
            UInt8(truncatingIfNeeded: lines >> 8), UInt8(truncatingIfNeeded: lines),
        ])
        return window
    }
}

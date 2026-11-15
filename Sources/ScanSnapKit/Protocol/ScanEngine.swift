import Foundation

/// One side of a scanned sheet as packed 8-bit RGB.
public struct ScannedPage: Sendable {
    public enum Side: String, Sendable { case front, back }

    public let side: Side
    public let sheetIndex: Int
    public let width: Int
    public let height: Int
    public let resolution: Int
    public let rgb: [UInt8]

    public init(side: Side, sheetIndex: Int, width: Int, height: Int, resolution: Int, rgb: [UInt8]) {
        self.side = side
        self.sheetIndex = sheetIndex
        self.width = width
        self.height = height
        self.resolution = resolution
        self.rgb = rgb
    }
}

public enum ScanError: Error, CustomStringConvertible {
    case noPaper
    case cancelled
    case coverOpen
    case paperJam(code: UInt8)
    case unsupportedResolution(Int)

    public var description: String {
        switch self {
        case .noPaper: "No paper in the feeder."
        case .cancelled: "Scanning was stopped."
        case .coverOpen: "The scanner cover is open."
        case let .paperJam(code): String(format: "Paper feed error (scanner code 0x%02X).", code)
        case let .unsupportedResolution(dpi): "\(dpi) dpi is not supported."
        }
    }

    public var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }
}

/// Calibrates the S1300 and scans duplex sheets.
///
/// The command sequence follows ScanSnap Manager; calibration
/// targets and per-resolution payloads follow SANE's `epjitsu` backend.
public final class ScanEngine {
    public let device: ScannerDevice
    public let profile: S300Profile
    public var log: ((String) -> Void)?
    /// Phase updates for UI ("Calibrating…", "Scanning sheet 2…").
    public var onPhase: ((String) -> Void)?
    /// Polled between data blocks; returning true stops the scan and ejects the sheet.
    public var isCancelled: () -> Bool = { false }

    private var transport: USBTransport { device.transport }
    private var isPrepared = false

    // Channel order in raw planes is blue, red, green.
    private let whiteFactor: [Double] = [1.0, 0.93, 0.98]
    private let fineGainTarget: [Double] = [185, 150]
    private let coarseOffsetTarget = 15
    private let coarseGainRange = 88...92
    /// Front-side image starts half an inch after the back-side image.
    private var frontSkipLines: Int { profile.yResolution / 2 }

    public init(device: ScannerDevice, dpi: Int) throws {
        self.device = device
        let usbPower = try device.hardwareStatus().raw[0] & 0x01 != 0
        guard let profile = S300Profile.best(forDPI: dpi, usbPower: usbPower),
              profile.xResolution == profile.yResolution
        else { throw ScanError.unsupportedResolution(dpi) }
        self.profile = profile
    }

    // MARK: Batch

    /// Scans sheets until the feeder is empty. Returns the number of sheets scanned.
    @discardableResult
    public func scanBatch(onSheet: (_ front: ScannedPage, _ back: ScannedPage) throws -> Void) throws -> Int {
        let sensors = try device.sensors()
        if sensors.coverOpen { throw ScanError.coverOpen }
        if !sensors.paperLoaded, !sensors.paperAtTop { throw ScanError.noPaper }

        var sheet = 0
        defer { try? device.setLamp(false) }
        while true {
            let status = try whenNotBusy { try device.hardwareStatus() }
            if status.hasError {
                log?(String(format: "Cleared latched scanner status 0x%02X", status.errorCode))
            }
            // Verified on hardware: the S1300 often pre-feeds the next sheet to the top sensor
            // while ejecting, so a staged sheet counts as paper.
            guard try ingestSheet(isFirst: sheet == 0) else {
                if sheet == 0 { throw ScanError.noPaper }
                break
            }
            if !isPrepared {
                onPhase?("Calibrating…")
                try prepare()
            }
            onPhase?("Scanning sheet \(sheet + 1)…")
            // ScanSnap Manager sends lamp on and the scan window before every page.
            if sheet > 0 {
                try device.setLamp(true)
                try device.send(.setWindow, payload: profile.scanWindow(lines: profile.maxY))
            }
            try device.send(.startPage)
            let (front, back) = try readSheet(index: sheet)
            try onSheet(front, back)
            sheet += 1
        }
        return sheet
    }

    /// The scanner NAKs status queries while it finishes ejecting a sheet; wait up to ~5 s.
    private func whenNotBusy<T>(_ query: () throws -> T) throws -> T {
        for _ in 0..<50 {
            do {
                return try query()
            } catch ScannerError.shortReply(_, _, got: 1) {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        return try query()
    }

    private func sensorsAfterEject() throws -> SensorState {
        try whenNotBusy { try device.sensors() }
    }

    private func prepare() throws {
        // ScanSnap Manager's scan mode setup for automatic page size: paper-length detection on,
        // over-scan, double-feed setting. Without B2 the scanner keeps feeding past each sheet's
        // trailing edge looking for more paper, pausing at the end of the last sheet.
        for (command, value) in [(ESCCommand.paperLengthDetection, UInt8(0x01)), (.overScan, 0x03), (.doubleFeedDetection, 0x80)] {
            do {
                try device.send(command, payload: [value])
            } catch {
                log?("Mode \(command) not accepted: \(error)")
            }
        }
        log?("Calibrating at \(profile.xResolution) dpi (\(profile.usbPower ? "USB" : "AC") power)…")
        try coarseCalibrate()
        try fineCalibrate()
        try sendLinearLUT()
        try device.setLamp(true)
        try device.send(.setWindow, payload: profile.scanWindow(lines: profile.maxY))
        isPrepared = true
    }

    /// Picks the next sheet with `D4 01`. Verified on hardware: sending `D4 00` first (as
    /// ScanSnap Manager does) makes the S1300 refuse every following pick.
    /// Verified on hardware: right after a sheet ejects the S1300 refuses picks for a few seconds,
    /// so keep retrying for a while before deciding the batch is over.
    private func ingestSheet(isFirst: Bool) throws -> Bool {
        let sensors = try sensorsAfterEject()
        if sensors.paperAtTop { return true }
        if !isFirst, !sensors.paperLoaded { return false }
        let deadline = Date().addingTimeInterval(isFirst ? 2 : 10)
        var attempt = 0
        while true {
            attempt += 1
            if try paperControl(0x01) {
                if attempt > 1 { log?("Sheet picked after \(attempt) attempts") }
                return true
            }
            if isCancelled() || Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        log?("Feeder refused \(attempt) pick attempts")
        return false
    }

    /// Returns false when the scanner NAKs the payload (no sheet picked).
    private func paperControl(_ value: UInt8) throws -> Bool {
        try transport.write(ESCCommand.paper.bytes)
        guard try transport.read(1).first == 0x06 else { return false }
        try transport.write([value])
        switch try transport.read(1).first {
        case 0x06: return true
        case 0x15, 0x00: return false
        case let status: throw ScannerError.unexpectedStatus(.paper, status ?? 0xFF)
        }
    }

    // MARK: Sheet transfer

    private func readSheet(index: Int) throws -> (ScannedPage, ScannedPage) {
        try RealtimeThread.run { try transferSheet(index: index) }
    }

    private func transferSheet(index: Int) throws -> (ScannedPage, ScannedPage) {
        let width = profile.planeWidth
        let rowBytes = width * 3
        var totalBytes = profile.maxY * profile.lineStride
        var received = 0
        var front = [UInt8](repeating: 0, count: profile.maxY * rowBytes)
        var back = [UInt8](repeating: 0, count: profile.maxY * rowBytes)
        var frontRows = 0, backRows = 0
        var usbTime = 0.0, hostTime = 0.0
        var commandTime = 0.0, dataTime = 0.0, infoTime = 0.0, blocks = 0
        let sheetStart = Date()
        let fullBlock = profile.blockHeight * profile.lineStride
        let buffer = NSMutableData(length: fullBlock + 8)!

        while received < totalBytes {
            if isCancelled() {
                try? device.cancel()
                throw ScanError.cancelled
            }
            let blockBytes = min(profile.blockHeight * profile.lineStride, totalBytes - received)
            let usbStart = Date()
            try device.send(.imageBlock)
            let commandDone = Date()
            if buffer.length != blockBytes + 8 { buffer.length = blockBytes + 8 }
            var got = try transport.read(into: buffer)
            while got < blockBytes + 8 {
                let more = try transport.read(blockBytes + 8 - got)
                guard !more.isEmpty else {
                    throw ScannerError.shortReply(.imageBlock, expected: blockBytes + 8, got: got)
                }
                buffer.replaceBytes(in: NSRange(location: got, length: more.count), withBytes: more)
                got += more.count
            }
            let dataDone = Date()
            let info = try device.query(.imageLengthInfo, length: 10)
            commandTime += commandDone.timeIntervalSince(usbStart)
            dataTime += dataDone.timeIntervalSince(commandDone)
            infoTime += Date().timeIntervalSince(dataDone)
            blocks += 1
            let blockTime = Date().timeIntervalSince(usbStart)
            usbTime += blockTime
            if blockTime > 0.3 {
                log?(String(format: "  slow block at line %d: %.2f s (status %@)", received / profile.lineStride, blockTime,
                            info.prefix(2).map { String(format: "%02X", $0) }.joined()))
            }
            if info[0] & 0x20 != 0 {
                throw ScanError.paperJam(code: try device.hardwareStatus().errorCode)
            }

            let hostStart = Date()
            let lines = blockBytes / profile.lineStride
            let firstRow = received / profile.lineStride
            let raw = buffer.bytes.assumingMemoryBound(to: UInt8.self)
            for line in 0..<lines {
                // Verified on hardware: show-through on the back reads mirrored only with this reversal.
                convertLine(raw, line: line, side: 1, reversed: true, into: &back, row: backRows)
                backRows += 1
                if firstRow + line >= frontSkipLines {
                    convertLine(raw, line: line, side: 0, reversed: false, into: &front, row: frontRows)
                    frontRows += 1
                }
            }
            hostTime += Date().timeIntervalSince(hostStart)
            received += blockBytes

            var paperLines = Int(info[6]) << 8 | Int(info[7])
            if paperLines % profile.blockHeight != 0 {
                paperLines += profile.blockHeight - paperLines % profile.blockHeight
            }
            if paperLines < profile.maxY {
                totalBytes = min(totalBytes, paperLines * profile.lineStride)
            }
        }
        log?(String(format: "Sheet %d: %d lines in %.1f s (USB %.1f s at %.1f MB/s, host %.2f s, realtime %@)", index + 1,
                    received / profile.lineStride, Date().timeIntervalSince(sheetStart), usbTime,
                    Double(received) / max(usbTime, 0.001) / 1_000_000, hostTime, RealtimeThread.lastApplied ? "on" : "off"))
        log?(String(format: "  %d blocks: command %.1f ms, data %.1f ms (%.1f MB/s while transferring), status %.1f ms per block",
                    blocks, commandTime / Double(max(blocks, 1)) * 1000, dataTime / Double(max(blocks, 1)) * 1000,
                    Double(received) / max(dataTime, 0.001) / 1_000_000, infoTime / Double(max(blocks, 1)) * 1000))

        front.removeSubrange((frontRows * rowBytes)...)
        back.removeSubrange((backRows * rowBytes)...)
        let dpi = profile.xResolution
        return (
            ScannedPage(side: .front, sheetIndex: index, width: width, height: frontRows, resolution: dpi, rgb: front),
            ScannedPage(side: .back, sheetIndex: index, width: width, height: backRows, resolution: dpi, rgb: back)
        )
    }

    /// Converts one raw line of one side to RGB. Raw pixel `k` of plane `p` (planes are B, R, G)
    /// for side `s` is at `line * lineStride + p * planeStride + k * 3 + s`.
    private func convertLine(_ src: UnsafePointer<UInt8>, line: Int, side: Int, reversed: Bool, into output: inout [UInt8], row: Int) {
        let width = profile.planeWidth
        let planeStride = profile.planeStride
        let base = line * profile.lineStride + side
        let outBase = row * width * 3
        output.withUnsafeMutableBufferPointer { dst in
            for x in 0..<width {
                let k = reversed ? width - 1 - x : x
                let p = base + k * 3
                let o = outBase + x * 3
                dst[o] = src[p + planeStride]
                dst[o + 1] = src[p + 2 * planeStride]
                dst[o + 2] = src[p]
            }
        }
    }

    /// Reads `length` bytes of a block plus its 8-byte trailer, returning only the data.
    /// The whole block is requested at once, like ScanSnap Manager does;
    /// small chunked reads leave the scanner's buffer filling up until it pauses the paper.
    private func readTransfer(_ length: Int) throws -> [UInt8] {
        var data = try transport.read(length + 8)
        while data.count < length + 8 {
            let more = try transport.read(length + 8 - data.count)
            guard !more.isEmpty else {
                throw ScannerError.shortReply(.imageBlock, expected: length + 8, got: data.count)
            }
            data.append(contentsOf: more)
        }
        data.removeSubrange(length...)
        return data
    }

    /// Splits raw lines into front/back buffers of `planeWidth` pixels, each pixel stored in
    /// plane order (B, R, G). Raw pixel `k` of plane `p` for side `s` is at
    /// `line * lineStride + p * planeStride + k * 3 + s`.
    private func descramble(_ raw: [UInt8], lines: Int, lineStride: Int, planeStride: Int, planeWidth: Int) -> [[UInt8]] {
        var sides = [[UInt8]](repeating: [UInt8](repeating: 0, count: lines * planeWidth * 3), count: 2)
        raw.withUnsafeBufferPointer { src in
            for side in 0..<2 {
                sides[side].withUnsafeMutableBufferPointer { dst in
                    var out = 0
                    for line in 0..<lines {
                        let base = line * lineStride + side
                        for k in 0..<planeWidth {
                            let pixel = base + k * 3
                            dst[out] = src[pixel]
                            dst[out + 1] = src[pixel + planeStride]
                            dst[out + 2] = src[pixel + 2 * planeStride]
                            out += 3
                        }
                    }
                }
            }
        }
        return sides
    }

    // MARK: Coarse calibration (analog offset and gain, 1B C6)

    private func coarseCalibrate() throws {
        var payload = S300Profile.coarseCalibration
        try device.send(.setWindow, payload: profile.coarseCalWindow)
        try coarseDark(&payload)
        try coarseLight(&payload)
    }

    private func calibrationLines(_ lines: Int) throws -> [[UInt8]] {
        try device.send(.littleImageBlock)
        let raw = try readTransfer(profile.calLineStride * lines)
        return descramble(raw, lines: lines, lineStride: profile.calLineStride,
                          planeStride: profile.calPlaneStride, planeWidth: profile.calPlaneWidth)
    }

    private func coarseDark(_ payload: inout [UInt8]) throws {
        try device.setLamp(false)
        var param = [63, 63], low = [-64, -64], high = [63, 63], done = [false, false]
        for _ in 0..<8 {
            payload[5] = UInt8(bitPattern: Int8(param[0]))
            payload[7] = UInt8(bitPattern: Int8(param[1]))
            try device.send(.agcSet, payload: payload)
            let sides = try calibrationLines(1)
            for side in 0..<2 where !done[side] {
                let average = sides[side].reduce(0) { $0 + Int($1) } / sides[side].count
                if average > coarseOffsetTarget {
                    high[side] = param[side]
                } else if average < coarseOffsetTarget {
                    low[side] = param[side]
                } else {
                    done[side] = true
                    continue
                }
                param[side] = (low[side] + high[side]) / 2
            }
            log?("coarse dark offset front \(param[0]) back \(param[1])")
            if done.allSatisfy({ $0 }) { break }
        }
    }

    private func coarseLight(_ payload: inout [UInt8]) throws {
        try device.setLamp(true)
        var param = [Int(payload[11]), Int(payload[13])], low = [0, 0], high = [63, 63], done = [false, false]
        let width = profile.calPlaneWidth
        for _ in 0..<8 {
            try device.send(.agcSet, payload: payload)
            let sides = try calibrationLines(1)
            for side in 0..<2 where !done[side] {
                var sums = [0.0, 0.0, 0.0], clipped = [0, 0, 0]
                for x in 0..<width {
                    for c in 0..<3 {
                        let value = sides[side][x * 3 + c]
                        sums[c] += Double(value)
                        if value == 255 { clipped[c] += 1 }
                    }
                }
                let average = Int((0..<3).map { sums[$0] * whiteFactor[$0] }.max()! / Double(width))
                let clippedPerMille = clipped.max()! * 1000 / width
                if clippedPerMille > 9 || average > coarseGainRange.upperBound {
                    high[side] = param[side]
                } else if average < coarseGainRange.lowerBound {
                    low[side] = param[side]
                } else {
                    done[side] = true
                    continue
                }
                param[side] = (low[side] + high[side]) / 2
            }
            log?("coarse gain front \(param[0]) back \(param[1])")
            if done.allSatisfy({ $0 }) { break }
            payload[11] = UInt8(param[0])
            payload[13] = UInt8(param[1])
        }
    }

    // MARK: Fine calibration (per-pixel offset/gain, 1B C3 + 1B C4)

    private func fineCalibrate() throws {
        let width = profile.calPlaneWidth
        let count = 2 * width * 3
        var table = [UInt8](repeating: 0, count: count * 2)

        func fill(gain: UInt8) {
            for i in 0..<count {
                table[i * 2] = 0
                table[i * 2 + 1] = gain
            }
        }

        fill(gain: 0xFF)
        try sendFineCalibration(table)
        try device.setLamp(true)
        let lowGain = try fineCalibrationLine()

        fill(gain: 0xBF)
        try sendFineCalibration(table)
        var highGain = try fineCalibrationLine()

        let gainDelta = 0xFF - 0xBF
        var slope = (0..<count).map { i -> Double in
            let delta = Int(highGain[i]) - Int(lowGain[i])
            return delta < gainDelta ? -1.0 : -Double(gainDelta) / Double(delta)
        }
        var lastError = [Double](repeating: 0, count: count)

        for attempt in 0..<16 {
            var errorSum = [[Double]](repeating: [0, 0, 0], count: 2)
            var errorSquares = [[Double]](repeating: [0, 0, 0], count: 2)
            for side in 0..<2 {
                for x in 0..<width {
                    for c in 0..<3 {
                        let i = (side * width + x) * 3 + c
                        let error = fineGainTarget[side] * whiteFactor[c] - Double(highGain[i])
                        if error * lastError[i] < 0 { slope[i] *= 0.75 }
                        lastError[i] = error
                        let gain = Int(table[i * 2 + 1]) + Int((error * slope[i]).rounded())
                        table[i * 2 + 1] = UInt8(clamping: gain)
                        errorSum[side][c] += error
                        errorSquares[side][c] += error * error
                    }
                }
            }
            var good = true
            var summary: [String] = []
            for side in 0..<2 {
                for c in 0..<3 {
                    let mean = errorSum[side][c] / Double(width)
                    let variance = (errorSquares[side][c] - errorSum[side][c] * errorSum[side][c] / Double(width)) / Double(width)
                    // Verified on hardware: a few columns can peg at the gain limit, leaving the
                    // variance near 7; after several passes accept that and repair them below.
                    let tolerance = attempt < 5 ? (1.0, 3.0) : (1.5, 8.0)
                    if abs(mean) > tolerance.0 || variance > tolerance.1 { good = false }
                    summary.append(String(format: "%.1f/%.1f", mean, variance))
                }
            }
            log?("fine calibration pass \(attempt + 1): \(good ? "converged" : "adjusting") mean/var front BRG \(summary[0..<3].joined(separator: " ")) back \(summary[3..<6].joined(separator: " "))")
            if good { break }
            try sendFineCalibration(table)
            highGain = try fineCalibrationLine()
        }

        let repaired = repairGainOutliers(&table, width: width)
        if repaired > 0 {
            log?("repaired \(repaired) calibration columns affected by dust on the reference")
            try sendFineCalibration(table)
        }
    }

    /// Replaces per-pixel gains that differ sharply from their neighbourhood median.
    /// Specks on the calibration reference otherwise become bright streaks in every scan.
    private func repairGainOutliers(_ table: inout [UInt8], width: Int, radius: Int = 15, limit: Int = 14) -> Int {
        var repaired = 0
        for side in 0..<2 {
            for channel in 0..<3 {
                let gains = (0..<width).map { Int(table[((side * width + $0) * 3 + channel) * 2 + 1]) }
                for x in 0..<width {
                    let window = gains[max(0, x - radius)...min(width - 1, x + radius)].sorted()
                    let median = window[window.count / 2]
                    if abs(gains[x] - median) > limit {
                        table[((side * width + x) * 3 + channel) * 2 + 1] = UInt8(median)
                        repaired += 1
                    }
                }
            }
        }
        return repaired
    }

    /// Averages 16 calibration lines per pixel; result is front then back, B/R/G per pixel.
    private func fineCalibrationLine() throws -> [UInt8] {
        let lines = 16
        try device.send(.setWindow, payload: profile.fineCalWindow)
        let sides = try calibrationLines(lines)
        let rowBytes = profile.calPlaneWidth * 3
        var averaged: [UInt8] = []
        averaged.reserveCapacity(rowBytes * 2)
        for side in sides {
            for column in 0..<rowBytes {
                var total = 0
                for line in 0..<lines { total += Int(side[line * rowBytes + column]) }
                averaged.append(UInt8((total + lines / 2) / lines))
            }
        }
        return averaged
    }

    private func sendFineCalibration(_ table: [UInt8]) throws {
        let width = profile.calPlaneWidth
        let planeStride = profile.calPlaneStride * 2
        var raw = [UInt8](repeating: 0, count: profile.calLineStride * 2)
        var input = 0
        for side in 0..<2 {
            for x in 0..<width {
                for plane in 0..<3 {
                    let out = plane * planeStride + x * 6 + side * 2
                    raw[out] = table[input]
                    raw[out + 1] = table[input + 1]
                    input += 2
                }
            }
        }
        try device.send(.setWindow, payload: profile.sendCalWindow)
        try sendWithHeader(.shadingBlack, header: profile.sendCal1Header, data: raw)
        try sendWithHeader(.shadingWhite, header: profile.sendCal2Header, data: raw)
    }

    private func sendWithHeader(_ command: ESCCommand, header: [UInt8], data: [UInt8]) throws {
        try transport.write(command.bytes)
        guard try transport.read(1).first == 0x06 else { throw ScannerError.nak(command) }
        try transport.write(header)
        try transport.write(data)
        guard try transport.read(1).first == 0x06 else { throw ScannerError.nak(command) }
    }

    // MARK: Gamma

    /// Identity 12-bit LUT: three little-endian tables of 4096 entries.
    private func sendLinearLUT() throws {
        let entries = 4096
        var lut = [UInt8](repeating: 0, count: entries * 6)
        for table in 0..<3 {
            for i in 0..<entries {
                lut[table * entries * 2 + i * 2] = UInt8(i & 0xFF)
                lut[table * entries * 2 + i * 2 + 1] = UInt8((i >> 8) & 0x0F)
            }
        }
        try device.send(.lut, payload: lut)
    }
}

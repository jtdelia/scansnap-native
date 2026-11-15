import Foundation
import CoreGraphics
import ImageIO
import YomiKit

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())
let verbose = arguments.contains("-v")
let command = arguments.first { !$0.hasPrefix("-") } ?? "info"

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func openScanner() throws -> ScannerDevice {
    guard let model = USBTransport.connectedModel() else {
        print("No ScanSnap S1300/S1300i found on USB.")
        exit(1)
    }
    let transport = try USBTransport(model: model)
    transport.timeout = 10
    if verbose { transport.trace = { print("   \($0)") } }
    print("Opened \(model.displayName)")
    return ScannerDevice(transport: transport)
}

func printInfo(_ scanner: ScannerDevice) throws {
    let info = try scanner.hardwareInfo()
    print("info     : \(hex(info.raw))")
    print("vendor   : \(info.vendor)  product: \(info.product)  firmware: \(info.firmwareRevision)")
    let status = try scanner.hardwareStatus()
    print("status   : \(hex(status.raw))  error=\(status.hasError) code=\(String(format: "0x%02X", status.errorCode))")
    let sensors = try scanner.sensors()
    print("sensors  : \(hex(sensors.raw))  cover-open=\(sensors.coverOpen) paper=\(sensors.paperLoaded) paper-at-top=\(sensors.paperAtTop) button=\(sensors.scanButton)")
}

func loadScanned(_ path: String, side: ScannedPage.Side) -> ScannedPage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = image.width, height = image.height
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    let ctx = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var rgb = [UInt8](); rgb.reserveCapacity(width * height * 3)
    for i in stride(from: 0, to: rgba.count, by: 4) { rgb.append(rgba[i]); rgb.append(rgba[i + 1]); rgb.append(rgba[i + 2]) }
    return ScannedPage(side: side, sheetIndex: 0, width: width, height: height, resolution: 300, rgb: rgb)
}

if command == "showthrough" {
    let paths = arguments.filter { $0.hasSuffix(".png") }
    guard paths.count == 2, let front = loadScanned(paths[0], side: .front), let back = loadScanned(paths[1], side: .back) else {
        print("usage: yomi showthrough front.png back.png"); exit(1)
    }
    let start = Date()
    let result = ShowThroughDetector.isShowThroughOnly(back: ColumnFlattener.flatten(back), front: ColumnFlattener.flatten(front))
    print(String(format: "show-through only: %@ (%.2f s)", "\(result)", Date().timeIntervalSince(start)))
    exit(0)
}

if command == "sheet" {
    // yomi sheet front.png back.png out-prefix [--no-bleed]
    let paths = arguments.filter { $0.hasSuffix(".png") }
    let prefix = arguments.last { !$0.hasSuffix(".png") && !$0.hasPrefix("-") && $0 != "sheet" } ?? "/tmp/sheet"
    guard paths.count == 2, let front = loadScanned(paths[0], side: .front), let back = loadScanned(paths[1], side: .back) else {
        print("usage: yomi sheet front.png back.png out-prefix"); exit(1)
    }
    var profile = ScanProfile(name: "Test")
    profile.reduceBleedThrough = !arguments.contains("--no-bleed")
    profile.searchablePDF = false
    do {
        let start = Date()
        let result = try SheetProcessor.process(front: front, back: back, profile: profile)
        result.notes.forEach { print("  \($0)") }
        for (index, page) in result.pages.enumerated() {
            let url = URL(fileURLWithPath: "\(prefix)-\(index + 1)-\(page.source.rawValue).png")
            try ImageWriter.write(page.image, to: url, resolution: page.resolution)
            print(String(format: "  page %d (%@): %d×%d @ %d dpi = %.3f×%.3f in", index + 1, page.source.rawValue,
                         page.image.width, page.image.height, page.resolution,
                         Double(page.image.width) / Double(page.resolution), Double(page.image.height) / Double(page.resolution)))
        }
        print(String(format: "  %d page(s), %d blank side(s), %.2f s", result.pages.count, result.blankSides, Date().timeIntervalSince(start)))
    } catch {
        print("error: \(error)"); exit(1)
    }
    exit(0)
}

if command == "process" {
    let inputs = arguments.filter { $0.hasSuffix(".png") }
    let output = URL(fileURLWithPath: arguments.first { $0.hasSuffix(".pdf") } ?? "/tmp/yomi-processed.pdf")
    do {
        var pages: [ProcessedPage] = []
        for path in inputs {
            let url = URL(fileURLWithPath: path)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let side: ScannedPage.Side = path.contains("back") ? .back : .front
            let start = Date()
            let width = image.width, height = image.height
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            let ctx = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var rgb = [UInt8](); rgb.reserveCapacity(width * height * 3)
            for i in stride(from: 0, to: rgba.count, by: 4) { rgb.append(rgba[i]); rgb.append(rgba[i + 1]); rgb.append(rgba[i + 2]) }
            let scanned = ScannedPage(side: side, sheetIndex: 0, width: width, height: height, resolution: 300, rgb: rgb)
            let page = try PageProcessor.process(scanned, options: ProcessingOptions())
            let ink = PageProcessor.inkFraction(page.image)
            print(String(format: "%@: %d×%d blank=%@ ink=%.4f (%.2f s)", url.lastPathComponent,
                         page.image.width, page.image.height, "\(page.isBlank)", ink, Date().timeIntervalSince(start)))
            try ImageWriter.write(page.image, to: url.deletingPathExtension().appendingPathExtension("processed.jpg"),
                                  type: .jpeg, resolution: 300)
            if !page.isBlank { pages.append(page) }
        }
        try PDFWriter.write(pages, to: output)
        print("wrote \(output.path) with \(pages.count) page(s)")
    } catch {
        print("error: \(error)")
        exit(1)
    }
    exit(0)
}

/// `yomi scan --photo`: processes and saves each sheet the way the app does for `profile`.
func scanPhotos(_ engine: ScanEngine, profile: ScanProfile, keepRaw: Bool) throws {
    let correction = ColorCorrection.forBatch(profile)
    if let line = correction.logLine { print("  \(line)") }
    let start = Date()
    var processed: [ProcessedPage] = []
    let sheets = try engine.scanBatch { front, back in
        if keepRaw {
            for page in [front, back] {
                let url = profile.folderURL.appendingPathComponent(
                    String(format: "sheet%02d-%@.png", page.sheetIndex + 1, page.side.rawValue))
                try ImageWriter.write(try page.cgImage(), to: url, resolution: page.resolution)
            }
        }
        let sheet = try SheetProcessor.process(front: front, back: back, profile: profile,
                                               colorProfile: correction.colorSpace)
        sheet.notes.forEach { print("  sheet \(front.sheetIndex + 1) \($0)") }
        print("  sheet \(front.sheetIndex + 1): \(sheet.pages.count) page(s), \(sheet.blankSides) blank side(s) skipped")
        processed += sheet.pages
    }
    let files = try DocumentWriter.save(processed, profile: profile)
    print(String(format: "Scanned %d sheet(s), %d page(s) in %.1f s → %@", sheets, processed.count,
                 Date().timeIntervalSince(start), profile.folderPath))
    files.forEach { print("  \($0.lastPathComponent)") }
    if let notice = correction.notice { print(notice) }
}

do {
    let scanner = try openScanner()
    switch command {
    case "info":
        try printInfo(scanner)

    case "firmware":
        let firmware: Firmware
        if let path = arguments.first(where: { $0.hasSuffix(".nal") }) {
            firmware = try Firmware(url: URL(fileURLWithPath: path))
        } else if let found = Firmware.locate(for: scanner.model) {
            firmware = found
        } else {
            print("No firmware found; pass a path to \(scanner.model.firmwarePrefix)XXXX.nal")
            exit(1)
        }
        let running = try scanner.hardwareInfo().firmwareRevision
        print("running firmware: '\(running)'  file: \(firmware.url.lastPathComponent) (\(firmware.version))")
        if running == firmware.version && !arguments.contains("--force") {
            print("Firmware already loaded.")
        } else {
            print("Uploading…")
            try scanner.uploadFirmware(firmware)
            print("Firmware booted.")
        }
        try scanner.setPowerLED(true)
        try printInfo(scanner)

    case "watch":
        print("Watching sensors (Ctrl-C to stop)…")
        var last: [UInt8] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        while true {
            let sensors = try scanner.sensors()
            let status = try scanner.hardwareStatus()
            let snapshot = sensors.raw + status.raw
            if snapshot != last {
                print("\(formatter.string(from: Date()))  1B33=\(hex(sensors.raw))  1B03=\(hex(status.raw))  button=\(sensors.scanButton)")
                last = snapshot
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

    case "scan":
        let photo = arguments.contains("--photo")
        let dpi = arguments.compactMap(Int.init).first ?? (photo ? 600 : 300)
        let folder = URL(fileURLWithPath: arguments.first { $0.hasPrefix("/") } ?? "/tmp/yomi")
        let photoProfile = photo ? ScanProfile.commandLinePhoto(dpi: dpi, folder: folder) : nil
        if photo, photoProfile == nil {
            print("--photo scans at 150, 200, 300 or 600 dpi")
            exit(1)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let firmware = Firmware.locate(for: scanner.model),
           try scanner.hardwareInfo().firmwareRevision != firmware.version {
            print("Loading firmware \(firmware.version)…")
            try scanner.uploadFirmware(firmware)
            try scanner.setPowerLED(true)
        }
        if arguments.contains("--button") {
            print("Press the Scan button…")
            let trace = scanner.transport.trace
            scanner.transport.trace = nil
            let deadline = Date().addingTimeInterval(240)
            var last = try scanner.sensors()
            while Date() < deadline {
                let state = try scanner.sensors()
                if state != last { print("  sensors \(hex(state.raw))") ; last = state }
                if state.scanButton { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            scanner.transport.trace = trace
            Thread.sleep(forTimeInterval: 0.5)
        }
        let engine = try ScanEngine(device: scanner, dpi: dpi)
        engine.log = { print("  \($0)") }
        let keepRaw = arguments.contains("--raw")
        if let photoProfile {
            try scanPhotos(engine, profile: photoProfile, keepRaw: keepRaw)
            break
        }
        let start = Date()
        var processed: [ProcessedPage] = []
        let sheets = try engine.scanBatch { front, back in
            for page in [front, back] {
                if keepRaw {
                    let url = folder.appendingPathComponent(String(format: "sheet%02d-%@.png", page.sheetIndex + 1, page.side.rawValue))
                    try ImageWriter.write(try page.cgImage(), to: url, resolution: page.resolution)
                }
                let result = try PageProcessor.process(page, options: ProcessingOptions())
                print("  sheet \(page.sheetIndex + 1) \(page.side.rawValue): \(result.image.width)×\(result.image.height)\(result.isBlank ? " (blank, skipped)" : "")")
                if !result.isBlank { processed.append(result) }
            }
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let pdf = folder.appendingPathComponent("\(formatter.string(from: Date())).pdf")
        try PDFWriter.write(processed, to: pdf)
        print(String(format: "Scanned %d sheet(s), %d page(s) in %.1f s → %@", sheets, processed.count, Date().timeIntervalSince(start), pdf.path))

    case "feed":
        // Raw experiment: yomi feed <steps…> where steps are d400, d401, cancel, wait, status, sensors
        for step in arguments.dropFirst() {
            switch step {
            case "d400", "d401":
                try scanner.transport.write([0x1B, 0xD4])
                let first = try scanner.transport.read(1)
                try scanner.transport.write([step == "d401" ? 0x01 : 0x00])
                print("\(step): \(hex(first)) \(hex(try scanner.transport.read(1)))")
            case "cancel":
                try scanner.transport.write([0x1B, 0x55])
                print("cancel: \(hex(try scanner.transport.read(1)))")
            case "wait":
                Thread.sleep(forTimeInterval: 1)
            case "status":
                print("status: \(hex(try scanner.hardwareStatus().raw))")
            case "sensors":
                print("sensors: \(hex(try scanner.sensors().raw))")
            default:
                print("unknown step \(step)")
            }
        }

    case "recover":
        do {
            print("recover: \(try scanner.recover())")
        } catch {
            print("soft recovery failed (\(error)); resetting USB device")
            try scanner.transport.resetDevice()
            print("reset done; reopen to reload firmware")
            exit(0)
        }
        try printInfo(scanner)

    case "feedprobe":
        let start = Date()
        while Date().timeIntervalSince(start) < 150 {
            let sensors = (try? scanner.sensors().raw).map(hex) ?? "busy"
            let status = (try? scanner.hardwareStatus().raw).map(hex) ?? "busy"
            try scanner.transport.write([0x1B, 0xD4])
            let first = try scanner.transport.read(1)
            try scanner.transport.write([0x01])
            let reply = try scanner.transport.read(1)
            print(String(format: "%5.1fs sensors %@ status %@ pick %@ %@", Date().timeIntervalSince(start), sensors, status, hex(first), hex(reply)))
            if reply.first == 0x06 { break }
            Thread.sleep(forTimeInterval: 2)
        }

    case "feedtest":
        func tryFeed(_ label: String) throws -> Bool {
            let state = try scanner.sensors()
            print("[\(label)] sensors \(hex(state.raw)) status \(hex(try scanner.hardwareStatus().raw))")
            try scanner.transport.write([0x1B, 0xD4]); _ = try scanner.transport.read(1)
            try scanner.transport.write([0x00]); _ = try scanner.transport.read(1)
            try scanner.transport.write([0x1B, 0xD4]); _ = try scanner.transport.read(1)
            try scanner.transport.write([0x01])
            let reply = try scanner.transport.read(1)
            print("[\(label)] feed reply \(hex(reply))")
            return reply.first == 0x06
        }
        if try tryFeed("as-is") { break }
        try scanner.setLamp(true); Thread.sleep(forTimeInterval: 0.5)
        if try tryFeed("after lamp on") { break }
        try scanner.setPowerLED(true); Thread.sleep(forTimeInterval: 0.5)
        if try tryFeed("after LED on") { break }
        try scanner.send(.energySaving, payload: [15]); Thread.sleep(forTimeInterval: 0.5)
        if try tryFeed("after energy-saving 15") { break }
        print("no wake method worked")

    default:
        print("usage: yomi [info|firmware [file.nal] [--force]|watch|scan [dpi] [/output/folder] [--photo]] [-v]")
    }
} catch {
    print("error: \(error)")
    exit(1)
}

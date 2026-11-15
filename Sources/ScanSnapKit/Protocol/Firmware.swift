import Foundation

/// A ScanSnap `.nal` firmware file: 256-byte `NDL1` header, 64 KiB image, checksum byte.
public struct Firmware: Sendable {
    public static let fileSize = 0x10101
    public static let imageRange = 0x100..<0x10100

    public let url: URL
    public let version: String
    public let image: Data

    public init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count == Self.fileSize else {
            throw ScannerError.firmwareFile("\(url.lastPathComponent) is \(data.count) bytes, expected \(Self.fileSize)")
        }
        guard data.prefix(4) == Data("NDL1".utf8) else {
            throw ScannerError.firmwareFile("\(url.lastPathComponent) has no NDL1 header")
        }
        self.url = url
        self.image = data.subdata(in: Self.imageRange)
        let name = url.deletingPathExtension().lastPathComponent
        self.version = name.split(separator: "_").last.map(String.init) ?? ""
    }

    public static let searchDirectories: [URL] = [
        URL(fileURLWithPath: "/Applications/ScanSnap/ScanSnap Manager.app/Contents/Resources/Firmware"),
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/ScanSnapNative/Firmware"),
    ]

    /// Newest firmware for `model` found in `directories`.
    public static func locate(for model: ScanSnapModel, in directories: [URL] = searchDirectories) -> Firmware? {
        let fm = FileManager.default
        let candidates = directories.flatMap { dir in
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "nal" && $0.lastPathComponent.hasPrefix(model.firmwarePrefix) }
        }
        return candidates.compactMap { try? Firmware(url: $0) }.max { $0.version < $1.version }
    }
}

import Foundation

/// A named scan configuration, modelled on ScanSnap Manager's "Scan Settings" profiles.
public struct ScanProfile: Codable, Identifiable, Hashable, Sendable {
    /// Image quality, matching ScanSnap Manager's names. Raw values are kept stable for saved
    /// settings ("fine" is Best/300 dpi from earlier versions).
    public enum Quality: String, Codable, CaseIterable, Sendable {
        case automatic, normal, better, fine, excellent

        /// Resolution the scanner runs at.
        public var dpi: Int {
            switch self {
            case .normal: 150
            case .automatic, .better, .fine: 300
            case .excellent: 600
            }
        }

        /// Resolution of the saved page. Automatic follows ScanSnap Manager: pages longer than
        /// 148 mm (A6 portrait) are saved at 200 dpi, shorter ones (receipts, cards) at 300 dpi.
        public func outputDPI(pageLengthInches: Double) -> Int {
            switch self {
            case .automatic: pageLengthInches > 148.0 / 25.4 ? 200 : 300
            case .better: 200
            case .normal, .fine, .excellent: dpi
            }
        }

        public var title: String {
            switch self {
            case .automatic: "Automatic resolution"
            case .normal: "Normal (150 dpi)"
            case .better: "Better (200 dpi)"
            case .fine: "Best (300 dpi)"
            case .excellent: "Excellent (600 dpi)"
            }
        }

        public var shortTitle: String {
            self == .automatic ? "Auto dpi" : "\(outputDPI(pageLengthInches: 11)) dpi"
        }
    }

    public enum ColorMode: String, Codable, CaseIterable, Sendable {
        case auto, color, gray, blackAndWhite

        public var title: String {
            switch self {
            case .auto: "Auto Color Detection"
            case .color: "Color"
            case .gray: "Gray"
            case .blackAndWhite: "Black & White"
            }
        }
    }

    public enum Sides: String, Codable, CaseIterable, Sendable {
        case duplex, simplex

        public var title: String {
            switch self {
            case .duplex: "Duplex (both sides)"
            case .simplex: "Simplex (front side)"
            }
        }
    }

    public enum FileFormat: String, Codable, CaseIterable, Sendable {
        case pdf, jpeg

        public var title: String {
            switch self {
            case .pdf: "PDF (*.pdf)"
            case .jpeg: "JPEG (*.jpg)"
            }
        }
    }

    public enum FileNaming: String, Codable, CaseIterable, Sendable {
        case dateTime, prefixAndNumber

        public var title: String {
            switch self {
            case .dateTime: "Date and time"
            case .prefixAndNumber: "Name and number"
            }
        }
    }

    public enum Compression: String, Codable, CaseIterable, Sendable {
        case low, medium, high

        public var title: String {
            switch self {
            case .low: "Low (best quality)"
            case .medium: "Medium"
            case .high: "High (smallest files)"
            }
        }

        public var jpegQuality: Double {
            switch self {
            case .low: 0.9
            case .medium: 0.75
            case .high: 0.55
            }
        }
    }

    public enum AfterScan: String, Codable, CaseIterable, Sendable {
        case nothing, openFile, revealInFinder

        public var title: String {
            switch self {
            case .nothing: "Do nothing"
            case .openFile: "Open the file"
            case .revealInFinder: "Show in Finder"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var folderPath: String
    public var afterScan: AfterScan
    public var quality: Quality
    public var colorMode: ColorMode
    public var sides: Sides
    public var skipBlankPages: Bool
    public var reduceBleedThrough: Bool
    public var autoRotate: Bool
    public var cropAndStraighten: Bool
    public var fileFormat: FileFormat
    public var searchablePDF: Bool
    public var compression: Compression
    public var fileNaming: FileNaming
    public var filePrefix: String
    public var nextNumber: Int
    public var numberDigits: Int

    public init(
        id: UUID = UUID(),
        name: String,
        folderPath: String = ScanProfile.defaultFolder.path,
        afterScan: AfterScan = .nothing,
        quality: Quality = .automatic,
        colorMode: ColorMode = .auto,
        sides: Sides = .duplex,
        skipBlankPages: Bool = true,
        reduceBleedThrough: Bool = true,
        autoRotate: Bool = true,
        cropAndStraighten: Bool = true,
        fileFormat: FileFormat = .pdf,
        searchablePDF: Bool = true,
        compression: Compression = .medium,
        fileNaming: FileNaming = .dateTime,
        filePrefix: String = "Scan",
        nextNumber: Int = 1,
        numberDigits: Int = 3
    ) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
        self.afterScan = afterScan
        self.quality = quality
        self.colorMode = colorMode
        self.sides = sides
        self.skipBlankPages = skipBlankPages
        self.reduceBleedThrough = reduceBleedThrough
        self.autoRotate = autoRotate
        self.cropAndStraighten = cropAndStraighten
        self.fileFormat = fileFormat
        self.searchablePDF = searchablePDF
        self.compression = compression
        self.fileNaming = fileNaming
        self.filePrefix = filePrefix
        self.nextNumber = nextNumber
        self.numberDigits = numberDigits
    }

    public static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/ScanSnap", isDirectory: true)

    public var folderURL: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }

    /// One-line summary for the progress panel and profile list.
    public var summary: String {
        var parts = [quality.shortTitle, colorMode.title, sides == .duplex ? "Duplex" : "Simplex"]
        parts.append(fileFormat == .pdf ? (searchablePDF ? "Searchable PDF" : "PDF") : "JPEG")
        return parts.joined(separator: " · ")
    }

    var processingOptions: ProcessingOptions {
        var options = ProcessingOptions()
        options.cropAndStraighten = cropAndStraighten
        options.skipBlankPages = skipBlankPages
        options.reduceBleedThrough = reduceBleedThrough
        options.autoRotate = autoRotate
        options.colorMode = colorMode
        options.quality = quality
        options.documentTone = !(colorMode == .color && fileFormat == .jpeg)
        return options
    }

    public static let defaults: [ScanProfile] = [
        ScanProfile(name: "Scan to ScanSnap Folder"),
        ScanProfile(name: "Receipts", quality: .automatic, colorMode: .auto, sides: .simplex),
        ScanProfile(name: "Photos", quality: .excellent, colorMode: .color, sides: .simplex,
                    skipBlankPages: false, reduceBleedThrough: false, autoRotate: false, fileFormat: .jpeg, searchablePDF: false,
                    compression: .low),
    ]
}

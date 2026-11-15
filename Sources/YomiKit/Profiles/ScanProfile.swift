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
        case pdf, jpeg, png, tiff, multiPageTIFF, heic

        public var title: String {
            switch self {
            case .pdf: "PDF (*.pdf)"
            case .jpeg: "JPEG (*.jpg)"
            case .png: "PNG (*.png)"
            case .tiff: "TIFF (*.tiff)"
            case .multiPageTIFF: "Multi-page TIFF (*.tiff)"
            case .heic: "HEIC (*.heic)"
            }
        }

        public var fileExtension: String {
            switch self {
            case .pdf: "pdf"
            case .jpeg: "jpg"
            case .png: "png"
            case .tiff, .multiPageTIFF: "tiff"
            case .heic: "heic"
            }
        }

        /// Whether every page is saved as its own image file.
        public var savesPagesSeparately: Bool {
            switch self {
            case .jpeg, .png, .tiff, .heic: true
            case .pdf, .multiPageTIFF: false
            }
        }

        /// Whether the compression setting applies: JPEG, HEIC and the images inside PDFs are lossy.
        public var usesCompression: Bool {
            switch self {
            case .pdf, .jpeg, .heic: true
            case .png, .tiff, .multiPageTIFF: false
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

    /// Where a batch is saved. Saving to Photos happens only in the app.
    public enum SaveDestination: String, Codable, CaseIterable, Sendable {
        case folder, photos, folderAndPhotos

        public var title: String {
            switch self {
            case .folder: "Folder"
            case .photos: "Photos"
            case .folderAndPhotos: "Folder and Photos"
            }
        }

        public var savesToFolder: Bool { self != .photos }
        public var savesToPhotos: Bool { self != .folder }
    }

    public var id: UUID
    public var name: String
    public var folderPath: String
    public var saveTo: SaveDestination
    /// Photos album the batch goes into, created the first time it is needed. Empty adds photos to the library only.
    public var photosAlbum: String
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
    /// Saved pages per file for PDF and multi-page TIFF; `nil` keeps the whole batch in one file.
    public var pagesPerFile: Int?
    public var namePattern: FileNamePattern
    /// Folders, separated by `/`, that each batch goes into inside the scan profile's folder. Empty saves
    /// straight into the folder.
    public var subfolderPattern: FileNamePattern
    public var nextNumber: Int
    public var numberDigits: Int
    /// Interpret colour with the scanner's colour profile and save in Display P3.
    public var correctColor: Bool
    /// Rotate prints upright by faces, using text only when there are none. Replaces `autoRotate` when on.
    public var rotateByFaces: Bool
    /// Save each file with Core Image's auto-adjustments, plus an untouched copy named with `_original`.
    public var autoEnhance: Bool
    /// Save the picture side of a print fed back-side-first as the photo, keeping the feed
    /// direction whenever the sides are not clearly the wrong way round.
    public var findPictureSide: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        folderPath: String = ScanProfile.defaultFolder.path,
        saveTo: SaveDestination = .folder,
        photosAlbum: String = "",
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
        pagesPerFile: Int? = nil,
        namePattern: FileNamePattern = .dateAndTime,
        subfolderPattern: FileNamePattern = [],
        nextNumber: Int = 1,
        numberDigits: Int = 3,
        correctColor: Bool = false,
        rotateByFaces: Bool = false,
        autoEnhance: Bool = false,
        findPictureSide: Bool = false
    ) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
        self.saveTo = saveTo
        self.photosAlbum = photosAlbum
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
        self.pagesPerFile = pagesPerFile
        self.namePattern = namePattern
        self.subfolderPattern = subfolderPattern
        self.nextNumber = nextNumber
        self.numberDigits = numberDigits
        self.correctColor = correctColor
        self.rotateByFaces = rotateByFaces
        self.autoEnhance = autoEnhance
        self.findPictureSide = findPictureSide
    }

    /// Every key is optional, so scan profiles saved by any earlier version keep loading.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ScanProfile(name: "New Profile")
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? defaults.id
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? defaults.name
        folderPath = try container.decodeIfPresent(String.self, forKey: .folderPath) ?? defaults.folderPath
        saveTo = try container.decodeIfPresent(SaveDestination.self, forKey: .saveTo)
            ?? (Self.builtInPhotoIDs.contains(id) ? .photos : .folder)
        photosAlbum = try container.decodeIfPresent(String.self, forKey: .photosAlbum) ?? defaults.photosAlbum
        afterScan = try container.decodeIfPresent(AfterScan.self, forKey: .afterScan) ?? defaults.afterScan
        quality = try container.decodeIfPresent(Quality.self, forKey: .quality) ?? defaults.quality
        colorMode = try container.decodeIfPresent(ColorMode.self, forKey: .colorMode) ?? defaults.colorMode
        sides = try container.decodeIfPresent(Sides.self, forKey: .sides) ?? defaults.sides
        skipBlankPages = try container.decodeIfPresent(Bool.self, forKey: .skipBlankPages) ?? defaults.skipBlankPages
        reduceBleedThrough = try container.decodeIfPresent(Bool.self, forKey: .reduceBleedThrough)
            ?? defaults.reduceBleedThrough
        autoRotate = try container.decodeIfPresent(Bool.self, forKey: .autoRotate) ?? defaults.autoRotate
        cropAndStraighten = try container.decodeIfPresent(Bool.self, forKey: .cropAndStraighten)
            ?? defaults.cropAndStraighten
        fileFormat = try container.decodeIfPresent(FileFormat.self, forKey: .fileFormat) ?? defaults.fileFormat
        searchablePDF = try container.decodeIfPresent(Bool.self, forKey: .searchablePDF) ?? defaults.searchablePDF
        compression = try container.decodeIfPresent(Compression.self, forKey: .compression) ?? defaults.compression
        pagesPerFile = try container.decodeIfPresent(Int.self, forKey: .pagesPerFile) ?? defaults.pagesPerFile
        namePattern = try (try? container.decodeIfPresent(FileNamePattern.self, forKey: .namePattern))
            ?? Self.convertedNamePattern(decoder.container(keyedBy: LegacyKeys.self), fileFormat: fileFormat)
        subfolderPattern = (try? container.decodeIfPresent(FileNamePattern.self, forKey: .subfolderPattern))
            ?? defaults.subfolderPattern
        nextNumber = try container.decodeIfPresent(Int.self, forKey: .nextNumber) ?? defaults.nextNumber
        numberDigits = try container.decodeIfPresent(Int.self, forKey: .numberDigits) ?? defaults.numberDigits
        correctColor = try container.decodePhotoSetting(forKey: .correctColor, profileID: id)
        rotateByFaces = try container.decodePhotoSetting(forKey: .rotateByFaces, profileID: id)
        autoEnhance = try container.decodePhotoSetting(forKey: .autoEnhance, profileID: id)
        findPictureSide = try container.decodePhotoSetting(forKey: .findPictureSide, profileID: id)
    }

    /// Keys that earlier versions saved and this version only reads.
    private enum LegacyKeys: String, CodingKey { case fileNaming, filePrefix }

    /// The name pattern matching an earlier version's file naming choice, so it names files exactly as before.
    private static func convertedNamePattern(_ container: KeyedDecodingContainer<LegacyKeys>,
                                             fileFormat: FileFormat) throws -> FileNamePattern {
        if try container.decodeIfPresent(String.self, forKey: .fileNaming) == "prefixAndNumber" {
            return try .nameAndNumber(container.decodeIfPresent(String.self, forKey: .filePrefix) ?? "Scan")
        }
        return fileFormat == .jpeg ? .dateTimeAndPage : .dateAndTime
    }

    public static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Yomi", isDirectory: true)

    public var folderURL: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }

    /// One-line summary for the progress panel and profile list.
    public var summary: String {
        var parts = [quality.shortTitle, colorMode.title, sides == .duplex ? "Duplex" : "Simplex"]
        switch fileFormat {
        case .pdf: parts.append(searchablePDF ? "Searchable PDF" : "PDF")
        case .jpeg: parts.append("JPEG")
        case .png: parts.append("PNG")
        case .tiff: parts.append("TIFF")
        case .multiPageTIFF: parts.append("Multi-page TIFF")
        case .heic: parts.append("HEIC")
        }
        return parts.joined(separator: " · ")
    }

    var processingOptions: ProcessingOptions {
        var options = ProcessingOptions()
        options.cropAndStraighten = cropAndStraighten
        options.skipBlankPages = skipBlankPages
        options.reduceBleedThrough = reduceBleedThrough
        options.autoRotate = autoRotate
        options.rotateByFaces = rotateByFaces
        options.colorMode = colorMode
        options.quality = quality
        options.documentTone = !(colorMode == .color && fileFormat.savesPagesSeparately)
        return options
    }

    /// IDs of the built-in "Photos – Quick" and "Photos – Keepers" scan profiles. Never change
    /// them: saved scan profiles with these IDs get new photo settings switched on.
    public static let builtInPhotoIDs: Set<UUID> = [
        UUID(uuidString: "4D211260-1BF8-426E-B9B8-4592CB2614D5")!,
        UUID(uuidString: "BC554CB0-727B-446B-BC17-638B509F0832")!,
    ]

    /// The built-in photo scan profiles, as new installs get them and existing installs gain them once.
    public static let builtInPhotoProfiles: [ScanProfile] = [
        photoProfile(id: "4D211260-1BF8-426E-B9B8-4592CB2614D5", name: "Photos – Quick", quality: .fine),
        photoProfile(id: "BC554CB0-727B-446B-BC17-638B509F0832", name: "Photos – Keepers", quality: .excellent),
    ]

    /// Text-only auto-rotate stays off because it misfires on photos; face rotation takes its place.
    private static func photoProfile(id: String, name: String, quality: Quality) -> ScanProfile {
        ScanProfile(id: UUID(uuidString: id)!, name: name, saveTo: .photos, quality: quality, colorMode: .color,
                    sides: .duplex, skipBlankPages: true, reduceBleedThrough: false, autoRotate: false,
                    fileFormat: .heic, searchablePDF: false, compression: .low, namePattern: .dateTimeAndPage,
                    correctColor: true, rotateByFaces: true, autoEnhance: true, findPictureSide: true)
    }

    /// The settings `yomi scan --photo` uses: "Photos – Keepers" saving only into `folder` at `dpi`,
    /// or `nil` when no quality saves at that resolution.
    public static func commandLinePhoto(dpi: Int, folder: URL) -> ScanProfile? {
        guard var profile = builtInPhotoProfiles.first(where: { $0.name == "Photos – Keepers" }),
              let quality = Quality.allCases.first(where: { $0 != .automatic && $0.outputDPI(pageLengthInches: 0) == dpi })
        else { return nil }
        profile.folderPath = folder.path
        profile.saveTo = .folder
        profile.quality = quality
        return profile
    }

    public static let defaults: [ScanProfile] = [
        ScanProfile(name: "Scan to Yomi Folder"),
        ScanProfile(name: "Receipts", quality: .automatic, colorMode: .auto, sides: .simplex),
    ] + builtInPhotoProfiles
}

extension KeyedDecodingContainer {
    /// Decodes a photo setting; when the key is missing, it is on for the built-in photo scan
    /// profiles and off for every other scan profile.
    func decodePhotoSetting(forKey key: Key, profileID: UUID) throws -> Bool {
        try decodeIfPresent(Bool.self, forKey: key) ?? ScanProfile.builtInPhotoIDs.contains(profileID)
    }
}

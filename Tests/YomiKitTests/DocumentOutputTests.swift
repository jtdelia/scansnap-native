import CryptoKit
import Foundation
import Testing
@testable import YomiKit

/// Pins the processed output of today's built-in scan profiles, so later photo work cannot
/// change what document scan profiles save.
struct DocumentOutputTests {
    /// A 3 × 4 inch off-white page at 300 dpi on the scanner's dark backing, with dark bars
    /// standing in for lines of text and a red patch.
    private static func syntheticPage() -> ScannedPage {
        let width = 1000, height = 1300, margin = 50
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let onPage = x >= margin && x < width - margin && y >= margin && y < height - margin
                let px = x - margin, py = y - margin
                let pixel: (UInt8, UInt8, UInt8)
                if !onPage {
                    pixel = (38, 38, 40)
                } else if px >= 600, px < 800, py >= 900, py < 1100 {
                    pixel = (200, 40, 45)
                } else if px >= 100, px < 800, py >= 100, py < 800, (py - 100) % 50 < 18, (px / 37) % 5 != 4 {
                    pixel = (52, 50, 48)
                } else {
                    pixel = (236, 232, 224)
                }
                let i = (y * width + x) * 3
                rgb[i] = pixel.0
                rgb[i + 1] = pixel.1
                rgb[i + 2] = pixel.2
            }
        }
        return ScannedPage(side: .front, sheetIndex: 0, width: width, height: height, resolution: 300, rgb: rgb)
    }

    private static func fingerprint(_ page: ProcessedPage) throws -> String {
        let data = try #require(page.image.dataProvider?.data as Data?)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(page.image.width)x\(page.image.height) \(page.resolution)dpi \(page.isColor ? "color" : "gray") \(hash)"
    }

    static let expected: [String: String] = [
        "Scan to Yomi Folder": "882x1182 300dpi color 83b55b2d4e3f98f8403a8eda42bc5dd826eda805ff25d9d226bae2019a1098ee",
        "Receipts": "882x1182 300dpi color 83b55b2d4e3f98f8403a8eda42bc5dd826eda805ff25d9d226bae2019a1098ee",
        "Photos": "882x1182 600dpi color d06b06c27798178cca35cc2f05dfb181910f0db109cc25df1487cf2b580ea79a",
    ]

    /// The built-in document scan profiles, and the "Photos" scan profile that installs from
    /// before the photo scan profiles keep.
    static let profiles = ScanProfile.defaults.filter { !ScanProfile.builtInPhotoIDs.contains($0.id) } + [
        ScanProfile(name: "Photos", quality: .excellent, colorMode: .color, sides: .simplex,
                    skipBlankPages: false, reduceBleedThrough: false, autoRotate: false, fileFormat: .jpeg,
                    searchablePDF: false, compression: .low, namePattern: .dateTimeAndPage),
    ]

    /// Auto-rotate reads text with Vision, so the page is processed off the task pool.
    @Test(arguments: profiles.map(\.name))
    func builtInProfileOutputIsUnchanged(name: String) async throws {
        let profile = try #require(Self.profiles.first { $0.name == name })
        let page = try await offTheTaskPool {
            try PageProcessor.process(Self.syntheticPage(), options: profile.processingOptions)
        }
        let fingerprint = try Self.fingerprint(page)
        #expect(fingerprint == Self.expected[name])
    }
}

import CoreGraphics
import Foundation

enum AppConstants {
    static let previewMaxSide: CGFloat = 1800
    static let thumbnailMaxSide: CGFloat = 220
    static let pdfRenderDPI: CGFloat = 260
    static let pdfMakeMaxSide: CGFloat = 4000

    static let defaultJPEGQuality: Int = 86
    static let pureSwiftJPEGQuality: Int = 88
    static let defaultDPI: Int = 200
    static let defaultMarginPts: Double = 20.0

    static let defaultCompressDPI: Int = 150
    static let defaultCompressJPEGQuality: Int = 80
    static let defaultCompressTargetMB: Double = 10.0

    // Q10 Reading orientation detection constants
    static let ocrOrientationMaxSide: CGFloat = 1600
    static let ocrImprovementFactor: Double = 1.15
    static let ocrDominanceRatio: Double = 0.55
    static let ocrMinCharacters: Int = 6
    static let ocrMinLineAlnumCount: Int = 2
    static let ocrPreferredLanguages: [String] = ["vi-VT", "en-US"]
}

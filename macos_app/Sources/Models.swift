import AppKit
import Foundation

enum PipelineEngine: String, CaseIterable, Identifiable {
    case hybridOpenCV = "hybrid_opencv"
    case pureSwiftVision = "pure_swift_vision"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hybridOpenCV: return "Hybrid OpenCV + Vision"
        case .pureSwiftVision: return "Pure Swift Vision"
        }
    }

    var shortBadge: String {
        switch self {
        case .hybridOpenCV: return "Hybrid 128-pt"
        case .pureSwiftVision: return "Swift Vision"
        }
    }

    var subtitle: String {
        switch self {
        case .hybridOpenCV:
            return "Đầy đủ Auto Color, Crop Đa Điểm 128 đỉnh, Nắn phẳng 3D & Cân lề"
        case .pureSwiftVision:
            return "Thuần macOS Vision + CoreImage (siêu nhanh, không cần Python)"
        }
    }
}

enum EnhanceMode: String, CaseIterable, Identifiable {
    case autoColor = "auto_color"
    case clean = "clean"
    case bw = "bw"
    case grayscale = "grayscale"
    case original = "original"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .autoColor: return "Auto Color"
        case .clean: return "Clean"
        case .bw: return "B&W"
        case .grayscale: return "Grayscale"
        case .original: return "Original"
        }
    }

    var descriptionText: String {
        switch self {
        case .autoColor:
            return "Chuẩn PDF Scanner: xóa bóng đèn/tay, làm sáng nền giấy, bù nét chữ mảnh & kẻ bảng"
        case .clean:
            return "Nâng sáng vùng tối nhẹ nhàng, khử bóng vừa phải, giữ màu sắc tự nhiên"
        case .bw:
            return "Trắng đen tương phản cao giống bản in máy photocopy, chữ cực nét"
        case .grayscale:
            return "Thang xám mịn màng, cân bằng độ sáng đồng đều"
        case .original:
            return "Chỉ cắt viền và nắn phẳng trang, giữ nguyên toàn bộ màu gốc"
        }
    }

    var swiftVisionFallbackMode: String {
        switch self {
        case .autoColor, .clean: return "clean"
        case .grayscale: return "grayscale"
        case .bw: return "bw"
        case .original: return "original"
        }
    }

    var pureSwiftEffectiveTitle: String {
        switch self {
        case .autoColor: return "Clean (CoreImage)"
        case .clean: return "Clean"
        case .grayscale: return "Grayscale"
        case .bw: return "B&W"
        case .original: return "Original"
        }
    }
}

enum CropEngine: String, CaseIterable, Identifiable {
    case auto = "auto"
    case vision = "vision"
    case opencv = "opencv"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto (Vision → OpenCV)"
        case .vision: return "Apple Vision"
        case .opencv: return "OpenCV Contour"
        }
    }
}

enum PageSizePreset: String, CaseIterable, Identifiable {
    case a4 = "a4"
    case letter = "letter"
    case fit = "fit"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .a4: return "A4"
        case .letter: return "Letter"
        case .fit: return "Fit theo ảnh"
        }
    }
}

enum PreviewDisplayMode: String, CaseIterable, Identifiable {
    case splitSlider = "Kéo rèm Trước ↔ Sau"
    case toggleSingle = "Bật / Tắt 1 Khung"
    case sideBySide = "Đặt Cạnh Nhau"
    case pdfResult = "PDF Đã Xuất"

    var id: String { rawValue }
}

enum StudioTask: String, CaseIterable, Identifiable {
    case scan
    case pair
    case split
    case mergeRotate
    case compress

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scan: return "Scan"
        case .pair: return "Ghép 2 mặt"
        case .split: return "Tách PDF"
        case .mergeRotate: return "Gộp / Xoay"
        case .compress: return "Nén nhẹ"
        }
    }

    var fullTitle: String {
        switch self {
        case .scan: return "Scan & Làm Nét Tài Liệu"
        case .pair: return "Ghép Trang Trước + Mặt Sau"
        case .split: return "Tách & Trích Xuất Trang PDF"
        case .mergeRotate: return "Gộp & Xoay PDF Giữ Nguyên Gốc"
        case .compress: return "Nén Giảm Dung Lượng PDF"
        }
    }

    var subtitle: String {
        switch self {
        case .scan: return "Khử bóng, cắt viền tự động & xuất PDF sắc nét"
        case .pair: return "Tự động kẹp trang mặt sau vào mỗi trang mặt trước"
        case .split: return "Tách từng trang lẻ hoặc lấy theo dải trang (vd: 1-3, 5)"
        case .mergeRotate: return "Gộp nhiều file/trang hoặc xoay chiều trang PDF"
        case .compress: return "Giảm nhanh dung lượng PDF nặng xuống dưới 10 MB"
        }
    }

    var icon: String {
        switch self {
        case .scan: return "doc.viewfinder.fill"
        case .pair: return "rectangle.on.rectangle.angled"
        case .split: return "scissors"
        case .mergeRotate: return "square.stack.3d.up.fill"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        }
    }

    var dropzoneTitle: String {
        switch self {
        case .scan: return "Kéo thả Ảnh, PDF hoặc Thư mục vào đây"
        case .pair: return "Kéo thả file PDF Mặt trước (hoặc bộ ảnh) vào đây"
        case .split: return "Kéo thả file PDF cần tách vào đây"
        case .mergeRotate: return "Kéo thả file PDF để xoay hoặc nhiều file để gộp"
        case .compress: return "Kéo thả file PDF nặng cần nén vào đây"
        }
    }

    var dropzoneSubtitle: String {
        switch self {
        case .scan: return "Hỗ trợ JPG, PNG, HEIC, WebP, TIFF và PDF • Tự sắp xếp A→Z & làm nét Auto Color"
        case .pair: return "Tự động kẹp trang mặt sau vào sau mỗi trang mặt trước"
        case .split: return "Tách từng trang lẻ hoặc trích xuất theo dải trang (vd: 1-3, 5)"
        case .mergeRotate: return "Giữ nguyên chất lượng vector gốc của tài liệu PDF"
        case .compress: return "Giảm nhanh dung lượng xuống dưới 10 MB theo mức DPI tùy chọn"
        }
    }

    var dropzonePrimaryButtonTitle: String {
        switch self {
        case .scan: return "Chọn Ảnh / PDF / Thư mục..."
        case .pair: return "Chọn PDF Mặt trước..."
        case .split: return "Chọn file PDF cần tách..."
        case .mergeRotate: return "Chọn file PDF..."
        case .compress: return "Chọn PDF cần nén..."
        }
    }

    var acceptsImagesDirectly: Bool {
        switch self {
        case .scan, .pair, .mergeRotate: return true
        case .split, .compress: return false
        }
    }
}

struct ScanSettings: Equatable {
    var engine: PipelineEngine = .hybridOpenCV
    var mode: EnhanceMode = .autoColor
    var autoCrop: Bool = true
    var cropEngine: CropEngine = .auto
    var multipointPoints: Int = 32
    var flattenSurface: Bool = true
    var balanceSymmetry: Bool = false
    var minConfidence: Double = 0.45
    var jpegQuality: Int = AppConstants.defaultJPEGQuality
    var pageSize: PageSizePreset = .a4
    var dpi: Int = AppConstants.defaultDPI
    var margin: Double = AppConstants.defaultMarginPts
    /// Q9: Optional invisible Vision OCR text layer (off by default to prioritize speed; does not alter enhanced pixels).
    var enableOCR: Bool = false

    /// Signature of settings that affect enhanced image pixels (excludes pure PDF layout & OCR controls).
    var imageProcessingSignature: String {
        let resBucket = (pageSize == .fit) ? "fit" : "dpi_\(dpi)"
        return [
            engine.rawValue,
            mode.rawValue,
            autoCrop ? "crop1" : "crop0",
            cropEngine.rawValue,
            "mp\(multipointPoints)",
            flattenSurface ? "flat1" : "flat0",
            balanceSymmetry ? "sym1" : "sym0",
            String(format: "mc%.2f", minConfidence),
            "jq\(jpegQuality)",
            resBucket
        ].joined(separator: "|")
    }
}

struct PreflightReport: Equatable {
    let isHealthy: Bool
    let usingBundledPython: Bool
    let pythonPath: String
    let pythonVersion: String
    let opencvVersion: String
    let visionHelperAvailable: Bool
    let summary: String
    let remediation: String?
}

struct InputPageItem: Identifiable, Equatable {
    let id: UUID
    let sourceURL: URL
    let pageIndexInPDF: Int?
    let displayName: String
    var sourceFolderName: String?
    var rotationDegrees: Int
    var orientationChecked: Bool
    var thumbnail: NSImage?
    var originalPreview: NSImage?
    var processedPreviewURL: URL?
    var processedCacheKey: String?
    var scanError: String?

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        pageIndexInPDF: Int? = nil,
        displayName: String,
        sourceFolderName: String? = nil,
        rotationDegrees: Int = 0,
        orientationChecked: Bool = false,
        thumbnail: NSImage? = nil,
        originalPreview: NSImage? = nil,
        processedPreviewURL: URL? = nil,
        processedCacheKey: String? = nil,
        scanError: String? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.pageIndexInPDF = pageIndexInPDF
        self.displayName = displayName
        self.sourceFolderName = sourceFolderName
        self.rotationDegrees = rotationDegrees
        self.orientationChecked = orientationChecked
        self.thumbnail = thumbnail
        self.originalPreview = originalPreview
        self.processedPreviewURL = processedPreviewURL
        self.processedCacheKey = processedCacheKey
        self.scanError = scanError
    }

    static func == (lhs: InputPageItem, rhs: InputPageItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.sourceURL == rhs.sourceURL &&
        lhs.pageIndexInPDF == rhs.pageIndexInPDF &&
        lhs.displayName == rhs.displayName &&
        lhs.sourceFolderName == rhs.sourceFolderName &&
        lhs.rotationDegrees == rhs.rotationDegrees &&
        lhs.orientationChecked == rhs.orientationChecked &&
        lhs.processedPreviewURL == rhs.processedPreviewURL &&
        lhs.processedCacheKey == rhs.processedCacheKey &&
        lhs.scanError == rhs.scanError
    }
}

struct CompressionResult {
    let outputURL: URL
    let beforeBytes: Int64
    let afterBytes: Int64
    let pageCount: Int
    var vectorPagesPreserved: Int = 0
    var imagePagesRecompressed: Int = 0
    var targetAchieved: Bool = true
    var usedDPI: Int = AppConstants.defaultCompressDPI
    var usedQuality: Int = AppConstants.defaultCompressJPEGQuality
    var detailsMessage: String = ""

    var savedPercent: Double {
        guard beforeBytes > 0 else { return 0 }
        return max(0, (Double(beforeBytes - afterBytes) / Double(beforeBytes)) * 100.0)
    }
}

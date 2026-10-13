import AppKit
import ImageIO

/// Retain the encoded source, not a full resolution bitmap, while cropping.
struct ImageCropItem: Identifiable {
    static let previewDimension = 1600
    let id = UUID()
    let image: CGImage
    private let encoded: Data
    let pixelSize: CGSize

    init(url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize <= 128 * 1024 * 1024 else { throw ImageImportError.tooLarge }
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ImageImportError.unreadable }
        guard width <= OCRService.maximumPixels / height else { throw ImageImportError.tooLarge }
        guard let preview = Self.decode(source, maximum: Self.previewDimension) else { throw ImageImportError.unreadable }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        pixelSize = (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        encoded = data
        image = preview
    }

    func croppedImage(selection: CGRect?) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(encoded as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let original = Self.decode(source, maximum: Int(max(pixelSize.width, pixelSize.height))) else { throw ImageImportError.unreadable }
        guard let selection else { return original }
        let region = selection.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !region.isNull, region.width > 0, region.height > 0 else { throw ImageImportError.invalidCrop }
        let rect = CGRect(x: region.minX * CGFloat(original.width), y: region.minY * CGFloat(original.height),
                          width: region.width * CGFloat(original.width), height: region.height * CGFloat(original.height)).integral
        guard let cropped = original.cropping(to: rect) else { throw ImageImportError.invalidCrop }
        return cropped
    }

    private static func decode(_ source: CGImageSource, maximum: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum,
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary)
    }
}

enum ImageImportError: LocalizedError {
    case unreadable, tooLarge, invalidCrop
    var errorDescription: String? {
        switch self {
        case .unreadable: return "无法打开这张图片，请选择有效的图片文件。"
        case .tooLarge: return "图片过大，请先缩小到 4,000 万像素以内，文件不超过 128 MB。"
        case .invalidCrop: return "裁剪区域无效，请重新框选。"
        }
    }
}

enum ImageCropGeometry {
    static func selection(from start: CGPoint, to end: CGPoint, imageRect: CGRect) -> CGRect? {
        guard imageRect.width > 0, imageRect.height > 0, imageRect.contains(start) else { return nil }
        func normalized(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(1, max(0, (point.x-imageRect.minX)/imageRect.width)),
                    y: min(1, max(0, (point.y-imageRect.minY)/imageRect.height)))
        }
        let a = normalized(start), b = normalized(end)
        return CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(a.x-b.x), height: abs(a.y-b.y))
    }
}

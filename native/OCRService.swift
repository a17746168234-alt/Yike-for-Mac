import AppKit
import Vision
import CoreImage
import ImageIO

func smartMergedImageBlocks(_ rawBlocks: [RecognizedImageBlock]) -> [RecognizedImageBlock] {
    guard rawBlocks.count > 1 else { return rawBlocks }
    let sorted = rawBlocks.sorted { left, right in
        let verticalDifference = abs(left.boundingBox.midY - right.boundingBox.midY)
        if verticalDifference > max(left.boundingBox.height, right.boundingBox.height) * 0.45 {
            return left.boundingBox.midY > right.boundingBox.midY
        }
        return left.boundingBox.minX < right.boundingBox.minX
    }

    // Vision occasionally splits a visual line into several fragments. Join only
    // fragments with strong vertical overlap and a modest horizontal gap.
    var lines: [RecognizedImageBlock] = []
    for block in sorted {
        guard var previous = lines.last else {
            lines.append(block)
            continue
        }
        let overlap = max(0, min(previous.boundingBox.maxY, block.boundingBox.maxY)
            - max(previous.boundingBox.minY, block.boundingBox.minY))
        let overlapRatio = overlap / max(0.001, min(previous.boundingBox.height, block.boundingBox.height))
        let gap = block.boundingBox.minX - previous.boundingBox.maxX
        let sameLine = overlapRatio > 0.58
            && gap >= -0.012
            && gap < max(0.028, max(previous.boundingBox.height, block.boundingBox.height) * 1.55)
        if sameLine {
            previous = OCRDocument.merge([previous, block], reviewed: false) ?? previous
            lines[lines.count - 1] = previous
        } else {
            lines.append(block)
        }
    }

    let heights = lines.map(\.boundingBox.height).sorted()
    let medianHeight = heights[heights.count / 2]
    func isList(_ text: String) -> Bool {
        text.range(of: #"^\s*([\u2022\u00b7\u25aa\u25e6*-]|\d+[.)\u3001])\s*"#, options: .regularExpression) != nil
    }

    // Merge nearby body lines into paragraphs, while retaining headings, lists,
    // labels and buttons as independent editable translation regions.
    var paragraphs: [RecognizedImageBlock] = []
    for line in lines {
        guard var previous = paragraphs.last else {
            paragraphs.append(line)
            continue
        }
        let upper = previous.boundingBox
        let lower = line.boundingBox
        let verticalGap = upper.minY - lower.maxY
        let heightRatio = lower.height / max(upper.height, 0.001)
        let horizontalOverlap = max(0, min(upper.maxX, lower.maxX) - max(upper.minX, lower.minX))
            / max(0.001, min(upper.width, lower.width))
        let aligned = abs(upper.minX - lower.minX) < 0.045 || horizontalOverlap > 0.72
        let titleLike = upper.height > medianHeight * 1.48 || lower.height > medianHeight * 1.48
        let mayMerge = verticalGap >= -0.006
            && verticalGap < max(0.018, (upper.height + lower.height) * 0.68)
            && (0.68...1.48).contains(heightRatio)
            && aligned
            && !titleLike
            && !isList(previous.text)
            && !isList(line.text)
            && previous.text.count + line.text.count < 360
        if mayMerge {
            previous = OCRDocument.merge([previous, line], reviewed: false) ?? previous
            paragraphs[paragraphs.count - 1] = previous
        } else {
            paragraphs.append(line)
        }
    }
    return paragraphs
}


struct OCRRecognitionResult {
    let image: CGImage
    let blocks: [RecognizedImageBlock]
    let adjustments: [String]
}

/// All coordinates refer to the returned, oriented/deskewed image.
enum OCRService {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static let maximumPixels = 40_000_000

    static func recognize(at url: URL, preprocess: Bool = true) throws -> OCRRecognitionResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maximumPixels / height else {
            throw OCRFailure.imageTooLarge
        }
        // The thumbnail API applies EXIF orientation once and bounds memory use.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height)
        ]
        guard let original = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw OCRFailure.unreadable
        }
        var image = original
        var adjustments: [String] = []
        if preprocess {
            var bestScore = -Double.infinity
            var bestOrientation: CGImagePropertyOrientation = .up
            let preview = scaled(original, longestSide: 1800)
            for orientation: CGImagePropertyOrientation in [.up, .right, .down, .left] {
                try Task.checkCancellation()
                let rotated = try render(CIImage(cgImage: preview).oriented(orientation))
                let observations = try observations(in: rotated)
                let score = observations.reduce(0.0) { partial, observation in
                    guard let candidate = observation.topCandidates(1).first else { return partial }
                    let dx = Double(observation.topRight.x - observation.topLeft.x) * Double(rotated.width)
                    let dy = Double(observation.topRight.y - observation.topLeft.y) * Double(rotated.height)
                    let horizontal = max(0.05, dx / max(1, hypot(dx, dy)))
                    return partial + Double(candidate.confidence) * Double(min(80, candidate.string.count)) * horizontal
                }
                // Prefer the original direction for near-ties.
                if score > bestScore * 1.03 + 0.1 {
                    bestScore = score
                    bestOrientation = orientation
                }
            }
            if bestOrientation != .up {
                image = try render(CIImage(cgImage: image).oriented(bestOrientation))
                adjustments.append("已校正文字方向")
            }
            let observations = try observations(in: scaled(image, longestSide: 1800))
            let angles = observations.compactMap { observation -> Double? in
                guard (observation.topCandidates(1).first?.confidence ?? 0) > 0.6 else { return nil }
                let dx = (observation.topRight.x - observation.topLeft.x) * CGFloat(image.width)
                let dy = (observation.topRight.y - observation.topLeft.y) * CGFloat(image.height)
                guard dx > 0 else { return nil }
                let angle = atan2(Double(dy), Double(dx))
                return abs(angle) <= .pi / 18 ? angle : nil
            }.sorted()
            if !angles.isEmpty {
                let median = angles[angles.count / 2]
                if abs(median) > .pi / 360 {
                    let input = CIImage(cgImage: image)
                    // Expand the canvas; cropping to the old extent would cut off edge text.
                    image = try render(input.transformed(by: CGAffineTransform(rotationAngle: -median)))
                    adjustments.append("已纠正轻微倾斜")
                }
            }
        }
        try Task.checkCancellation()
        let originalObservations = try observations(in: image)
        var observations = originalObservations
        if preprocess, contrast(of: image) < 0.45 {
            let enhanced = CIImage(cgImage: image)
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.8, kCIInputSaturationKey: 0])
                .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.4])
            let enhancedObservations = try self.observations(in: render(enhanced))
            // Enhancement is OCR-only: do not bleach the image used for editing/export.
            if quality(enhancedObservations) >= quality(originalObservations) {
                observations = enhancedObservations
                adjustments.append("已增强低对比文字")
            }
        }
        let raw = observations.compactMap { observation -> RecognizedImageBlock? in
            let candidates = observation.topCandidates(3)
            guard let first = candidates.first else { return nil }
            let text = first.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RecognizedImageBlock(text: text, boundingBox: observation.boundingBox,
                                        confidence: first.confidence, candidates: candidates.map(\.string))
        }
        return OCRRecognitionResult(image: image, blocks: smartMergedImageBlocks(raw), adjustments: adjustments)
    }

    static func observations(in image: CGImage) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["en-US", "zh-Hans", "ja-JP", "ko-KR", "de-DE", "fr-FR"].filter(supported.contains)
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return request.results ?? []
    }

    static func quality(_ observations: [VNRecognizedTextObservation]) -> Double {
        observations.reduce(0) { $0 + Double($1.topCandidates(1).first?.confidence ?? 0)
            * Double($1.topCandidates(1).first?.string.count ?? 0) }
    }

    static func render(_ image: CIImage) throws -> CGImage {
        let extent = image.extent.integral
        let aligned = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        guard let output = context.createCGImage(aligned, from: CGRect(origin: .zero, size: extent.size)) else {
            throw OCRFailure.unreadable
        }
        return output
    }

    static func scaled(_ image: CGImage, longestSide: CGFloat) -> CGImage {
        let scale = min(1, longestSide / CGFloat(max(image.width, image.height)))
        return (try? render(CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale)))) ?? image
    }

    static func contrast(of image: CGImage) -> Double {
        var pixels = [UInt8](repeating: 0, count: 128 * 128)
        let success = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 128, height: 128,
                bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 128))
            return true
        }
        guard success else { return 1 }
        let sorted = pixels.sorted()
        return Double(Int(sorted[sorted.count * 99 / 100]) - Int(sorted[sorted.count / 100])) / 255
    }
}

enum OCRFailure: LocalizedError {
    case unreadable, imageTooLarge
    var errorDescription: String? {
        switch self {
        case .unreadable: return "无法读取图片，请换一张常见格式的图片。"
        case .imageTooLarge: return "图片无法读取或超过 4,000 万像素，请先裁剪或缩小图片。"
        }
    }
}

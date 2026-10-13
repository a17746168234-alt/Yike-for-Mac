import AppKit
import CoreText

struct ImageBackgroundSample {
    let leading: NSColor
    let trailing: NSColor
    let average: NSColor
    let complexity: CGFloat
}

func averageColor(_ colors: [NSColor]) -> NSColor {
    guard !colors.isEmpty else { return .windowBackgroundColor }
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    for color in colors {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        red += rgb.redComponent
        green += rgb.greenComponent
        blue += rgb.blueComponent
    }
    let count = CGFloat(colors.count)
    return NSColor(deviceRed: red / count, green: green / count, blue: blue / count, alpha: 1)
}

func imageBackgroundSample(
    representation: NSBitmapImageRep?,
    around normalized: CGRect
) -> ImageBackgroundSample {
    guard let representation, representation.pixelsWide > 1, representation.pixelsHigh > 1 else {
        return ImageBackgroundSample(leading: .windowBackgroundColor, trailing: .windowBackgroundColor, average: .windowBackgroundColor, complexity: 0)
    }

    func color(x: CGFloat, y: CGFloat) -> NSColor? {
        let clampedX = min(max(x, 0), 1)
        let clampedY = min(max(y, 0), 1)
        let pixelX = min(representation.pixelsWide - 1, max(0, Int(clampedX * CGFloat(representation.pixelsWide - 1))))
        let pixelY = min(representation.pixelsHigh - 1, max(0, Int(clampedY * CGFloat(representation.pixelsHigh - 1))))
        return representation.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB)
    }

    let xPadding = max(0.006, min(0.025, normalized.width * 0.10))
    let yPadding = max(0.004, min(0.018, normalized.height * 0.28))
    let verticalSamples = [normalized.minY, normalized.midY, normalized.maxY]
    let horizontalSamples = [normalized.minX, normalized.midX, normalized.maxX]
    let leadingColors = verticalSamples.compactMap { color(x: normalized.minX - xPadding, y: $0) }
    let trailingColors = verticalSamples.compactMap { color(x: normalized.maxX + xPadding, y: $0) }
    let edgeColors = leadingColors + trailingColors
        + horizontalSamples.compactMap { color(x: $0, y: normalized.minY - yPadding) }
        + horizontalSamples.compactMap { color(x: $0, y: normalized.maxY + yPadding) }
    let average = averageColor(edgeColors)
    let rgbAverage = average.usingColorSpace(.deviceRGB) ?? average
    let complexity: CGFloat
    if edgeColors.isEmpty {
        complexity = 0
    } else {
        complexity = edgeColors.reduce(0) { partial, value in
            let rgb = value.usingColorSpace(.deviceRGB) ?? value
            let delta = abs(rgb.redComponent - rgbAverage.redComponent)
                + abs(rgb.greenComponent - rgbAverage.greenComponent)
                + abs(rgb.blueComponent - rgbAverage.blueComponent)
            return partial + delta / 3
        } / CGFloat(edgeColors.count)
    }
    return ImageBackgroundSample(
        leading: averageColor(leadingColors.isEmpty ? edgeColors : leadingColors),
        trailing: averageColor(trailingColors.isEmpty ? edgeColors : trailingColors),
        average: average,
        complexity: complexity
    )
}

func renderedTranslationImage(
    source: NSImage,
    edits: [EditableImageTranslationBlock],
    style: ImageTranslationRenderStyle
) -> NSImage {
    let imageSize = source.size
    let bitmap = source.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
    let pixelWidth = bitmap?.pixelsWide ?? max(1, Int(imageSize.width.rounded()))
    let pixelHeight = bitmap?.pixelsHigh ?? max(1, Int(imageSize.height.rounded()))
    guard let outputRepresentation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return source.copy() as? NSImage ?? source
    }
    // Set the point size before creating the graphics context. On Retina images the
    // bitmap is commonly 2x the point size; creating the context first makes AppKit
    // draw the source into only one quarter of the output bitmap.
    outputRepresentation.size = imageSize
    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: outputRepresentation) else {
        return source.copy() as? NSImage ?? source
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    defer { NSGraphicsContext.restoreGraphicsState() }

    source.draw(
        in: NSRect(origin: .zero, size: imageSize),
        from: NSRect(origin: .zero, size: source.size),
        operation: .copy,
        fraction: 1
    )

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byWordWrapping

    // Estimate a common source line height so paragraph height is not mistaken for font size.
    let lineHeights = edits.map { edit -> CGFloat in
        let lines = max(1, edit.originalText.components(separatedBy: .newlines).count)
        return edit.boundingBox.height * imageSize.height / CGFloat(lines)
    }.sorted()
    var bodySize = min(36, max(8, (lineHeights.isEmpty ? 18 : lineHeights[lineHeights.count / 2]) * 0.72))
    let initialBodySize = bodySize
    let fits = edits.filter { $0.fontScale == 1 && !$0.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.compactMap { edit -> CGFloat? in
        let original = CGRect(x: edit.boundingBox.minX * imageSize.width, y: edit.boundingBox.minY * imageSize.height,
                              width: edit.boundingBox.width * imageSize.width, height: edit.boundingBox.height * imageSize.height)
        let text = edit.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("\n") && text.count < 32 && original.height > initialBodySize * 1.8 { return nil }
        var box = original.insetBy(dx: -min(imageSize.width * 0.024, max(4, original.width * 0.08)),
                                  dy: -min(imageSize.height * 0.016, max(3, original.height * 0.22)))
        box.origin.x = max(2, box.origin.x); box.origin.y = max(2, box.origin.y)
        box.size.width = min(box.width, imageSize.width - box.minX - 2)
        box.size.height = min(max(box.height, original.height * 1.45), imageSize.height - box.minY - 2)
        let rect = box.insetBy(dx: max(3, box.width * 0.035), dy: max(2, box.height * 0.08))
        return TextLayout.fontSize(for: edit.translatedText, in: rect.size, preferred: initialBodySize)
    }
    if let commonFit = fits.min() { bodySize = min(bodySize, commonFit) }
    for edit in edits {
        let translated = edit.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else { continue }

        let normalized = edit.boundingBox
        let originalRect = NSRect(
            x: normalized.minX * imageSize.width,
            y: normalized.minY * imageSize.height,
            width: normalized.width * imageSize.width,
            height: normalized.height * imageSize.height
        )
        let horizontalExpansion = min(imageSize.width * 0.024, max(4, originalRect.width * 0.08))
        let verticalExpansion = min(imageSize.height * 0.016, max(3, originalRect.height * 0.22))
        var box = originalRect.insetBy(dx: -horizontalExpansion, dy: -verticalExpansion)
        box.origin.x = max(2, box.origin.x)
        box.origin.y = max(2, box.origin.y)
        box.size.width = min(box.width, imageSize.width - box.minX - 2)
        box.size.height = min(max(box.height, originalRect.height * 1.45), imageSize.height - box.minY - 2)

        let sample = imageBackgroundSample(representation: bitmap, around: normalized)
        let trimmedOriginal = edit.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeList = trimmedOriginal.range(
            of: #"^([•·▪◦*-]|\d+[.)、])\s*"#,
            options: .regularExpression
        ) != nil
        let looksLikeTitle = !trimmedOriginal.contains("\n") && trimmedOriginal.count < 32 && originalRect.height > initialBodySize * 1.8
        let automaticAlignment: NSTextAlignment = (looksLikeList || originalRect.width > imageSize.width * 0.38) ? .left : .center
        paragraph.alignment = edit.alignment.resolved(automaticAlignment: automaticAlignment)
        let rgbBackground = sample.average.usingColorSpace(.deviceRGB) ?? sample.average
        let luminance = 0.2126 * rgbBackground.redComponent
            + 0.7152 * rgbBackground.greenComponent
            + 0.0722 * rgbBackground.blueComponent
        let textColor: NSColor
        let backgroundPath = NSBezierPath(
            roundedRect: box,
            xRadius: style == .natural ? max(1.5, box.height * 0.045) : max(3, box.height * 0.12),
            yRadius: style == .natural ? max(1.5, box.height * 0.045) : max(3, box.height * 0.12)
        )

        if style == .natural {
            if sample.complexity < 0.16 {
                NSGradient(starting: sample.leading, ending: sample.trailing)?.draw(in: backgroundPath, angle: 0)
                textColor = luminance > 0.58 ? NSColor(calibratedWhite: 0.08, alpha: 1) : .white
            } else {
                // Reconstruct the covered area from real texture immediately to
                // the left and right of the OCR box. Stretching both edge strips
                // toward the centre removes the old glyphs while preserving local
                // colour, lighting and texture without a GPU-dependent blur pass.
                NSGraphicsContext.saveGraphicsState()
                backgroundPath.addClip()
                let stripWidth = max(2, min(box.width * 0.10, imageSize.width * 0.018))
                let leadingSource = NSRect(
                    x: max(0, originalRect.minX - stripWidth),
                    y: box.minY,
                    width: min(stripWidth, max(0, originalRect.minX)),
                    height: box.height
                )
                let trailingX = min(imageSize.width, originalRect.maxX)
                let trailingSource = NSRect(
                    x: trailingX,
                    y: box.minY,
                    width: min(stripWidth, max(0, imageSize.width - trailingX)),
                    height: box.height
                )
                let leftHalf = NSRect(x: box.minX, y: box.minY, width: box.width * 0.56, height: box.height)
                let rightHalf = NSRect(x: box.midX, y: box.minY, width: box.width * 0.50, height: box.height)
                if leadingSource.width > 0 {
                    source.draw(in: leftHalf, from: leadingSource, operation: .copy, fraction: 1)
                }
                if trailingSource.width > 0 {
                    source.draw(in: rightHalf, from: trailingSource, operation: .sourceOver, fraction: 0.92)
                }
                NSGradient(
                    starting: sample.leading.withAlphaComponent(0.34),
                    ending: sample.trailing.withAlphaComponent(0.34)
                )?.draw(in: backgroundPath, angle: 0)
                NSGraphicsContext.restoreGraphicsState()
                sample.average.withAlphaComponent(0.18).setFill()
                backgroundPath.fill()
                NSColor.white.withAlphaComponent(luminance > 0.52 ? 0.16 : 0.09).setStroke()
                backgroundPath.lineWidth = 0.8
                backgroundPath.stroke()
                textColor = luminance > 0.52 ? NSColor(calibratedWhite: 0.08, alpha: 1) : .white
            }
        } else {
            NSColor(calibratedWhite: 0.05, alpha: 0.82).setFill()
            backgroundPath.fill()
            textColor = .white
        }

        let textRect = box.insetBy(dx: max(3, box.width * 0.035), dy: max(2, box.height * 0.08))
        let resolvedTextColor = edit.textColor.resolved(automaticColor: textColor)
        let preferredFontSize = min(54, max(1, (looksLikeTitle ? initialBodySize * 1.3 : bodySize) * CGFloat(edit.fontScale)))
        let fontSize = TextLayout.fontSize(for: translated, in: textRect.size, preferred: preferredFontSize, bold: looksLikeTitle)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: looksLikeTitle ? .bold : .semibold),
            .foregroundColor: resolvedTextColor,
            .paragraphStyle: paragraph,
            .strokeColor: luminance > 0.58 ? NSColor.black.withAlphaComponent(0.28) : NSColor.white.withAlphaComponent(0.34),
            .strokeWidth: -0.35
        ]
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: textRect).addClip()
        // Measure and draw with the same layout engine so wrapping cannot diverge.
        let text = NSAttributedString(string: translated, attributes: attributes)
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text),
            CFRange(location: 0, length: text.length), CGPath(rect: textRect, transform: nil), nil)
        graphicsContext.cgContext.textMatrix = .identity
        CTFrameDraw(frame, graphicsContext.cgContext)
        NSGraphicsContext.restoreGraphicsState()
    }

    graphicsContext.flushGraphics()
    let output = NSImage(size: imageSize)
    output.addRepresentation(outputRepresentation)
    return output
}

import AppKit
import CoreText

enum TextLayout {
    static func fits(_ text: String, in size: CGSize, fontSize: CGFloat, bold: Bool = false) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        let font = NSFont.systemFont(ofSize: fontSize, weight: bold ? .bold : .semibold)
        let string = NSAttributedString(string: text, attributes: [.font: font])
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: string.length),
                                            CGPath(rect: CGRect(origin: .zero, size: size), transform: nil), nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        guard visible.length == string.length else { return false }
        let lines = CTFrameGetLines(frame) as! [CTLine]
        return lines.allSatisfy { CTLineGetTypographicBounds($0, nil, nil, nil) <= Double(size.width) + 0.5 }
    }

    static func fontSize(for text: String, in size: CGSize, preferred: CGFloat, bold: Bool = false) -> CGFloat {
        guard !text.isEmpty, size.width > 0, size.height > 0 else { return 1 }
        var low: CGFloat = 1, high = max(1, preferred)
        for _ in 0..<14 {
            let mid = (low + high) / 2
            if fits(text, in: size, fontSize: mid, bold: bold) { low = mid } else { high = mid }
        }
        // Leave padding for AppKit/CoreText rounding differences at Retina scale.
        return max(1, low * 0.96)
    }
}

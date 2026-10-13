import Foundation

enum OCRDocument {
    enum SplitAxis: String, CaseIterable { case rows = "上下", columns = "左右" }

    static func ordered(_ blocks: [RecognizedImageBlock]) -> [RecognizedImageBlock] {
        // Quantized rows form a transitive ordering, unlike pairwise y tolerances.
        blocks.sorted {
            let lhs = Int(($0.boundingBox.midY * 40).rounded())
            let rhs = Int(($1.boundingBox.midY * 40).rounded())
            return lhs == rhs ? $0.boundingBox.minX < $1.boundingBox.minX : lhs > rhs
        }
    }

    static func normalizedRect(from start: CGPoint, to end: CGPoint, imageRect: CGRect) -> CGRect? {
        guard imageRect.width > 0, imageRect.height > 0 else { return nil }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(imageRect)
        guard !rect.isNull, rect.width >= 8, rect.height >= 8 else { return nil }
        return CGRect(x: (rect.minX - imageRect.minX) / imageRect.width,
                      y: 1 - (rect.maxY - imageRect.minY) / imageRect.height,
                      width: rect.width / imageRect.width, height: rect.height / imageRect.height)
    }

    static func split(_ block: RecognizedImageBlock, at offset: Int, axis: SplitAxis) -> [RecognizedImageBlock] {
        guard offset > 0, offset < block.text.count else { return [block] }
        let index = block.text.index(block.text.startIndex, offsetBy: offset)
        let first = String(block.text[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
        let second = String(block.text[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty, !second.isEmpty else { return [block] }
        var a = block.boundingBox, b = block.boundingBox
        let fraction = min(0.9, max(0.1, CGFloat(first.count) / CGFloat(first.count + second.count)))
        if axis == .rows {
            a.size.height *= fraction
            a.origin.y = block.boundingBox.maxY - a.height
            b.size.height *= 1 - fraction
        } else {
            a.size.width *= fraction
            b.origin.x += a.width
            b.size.width *= 1 - fraction
        }
        return [RecognizedImageBlock(text: first, boundingBox: a, reviewed: true),
                RecognizedImageBlock(text: second, boundingBox: b, reviewed: true)]
    }

    static func merge(_ blocks: [RecognizedImageBlock], reviewed: Bool = true) -> RecognizedImageBlock? {
        let ordered = ordered(blocks)
        guard let first = ordered.first else { return nil }
        // Same-line fragments use a space; stacked regions retain a line break.
        // This also preserves sentence continuity for translation after automatic merges.
        let separators = zip(ordered, ordered.dropFirst()).map { left, right -> String in
            let overlap = min(left.boundingBox.maxY, right.boundingBox.maxY)
                - max(left.boundingBox.minY, right.boundingBox.minY)
            return overlap > min(left.boundingBox.height, right.boundingBox.height) * 0.58 ? " " : "\n"
        }
        func joined(_ parts: [String]) -> String {
            parts.enumerated().reduce("") { $0 + ($1.offset == 0 ? "" : separators[$1.offset - 1]) + $1.element }
        }
        let text = joined(ordered.map(\.text))
        let bounds = ordered.dropFirst().reduce(first.boundingBox) { $0.union($1.boundingBox) }
        // Keep alternatives from each constituent region, changing one region at a time.
        var alternatives = [text]
        for (index, block) in ordered.enumerated() {
            for candidate in (block.candidates ?? []).filter({ $0 != block.text }).prefix(2) {
                var parts = ordered.map(\.text)
                parts[index] = candidate
                let variant = joined(parts)
                if !alternatives.contains(variant) { alternatives.append(variant) }
            }
        }
        return RecognizedImageBlock(text: text, boundingBox: bounds,
                                    confidence: ordered.compactMap(\.confidence).min(),
                                    candidates: Array(alternatives.prefix(9)), reviewed: reviewed)
    }
}

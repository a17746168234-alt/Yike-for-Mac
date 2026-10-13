import Foundation

struct ImageZoomPolicy {
    static let minimum = 1.0
    static let maximum = 3.0

    static func shouldZoom(hasPreciseScrollingDeltas: Bool) -> Bool {
        !hasPreciseScrollingDeltas
    }

    static func adjustedZoom(
        current: Double,
        deviceDeltaY: Double
    ) -> Double {
        guard deviceDeltaY != 0 else {
            return min(max(current, minimum), maximum)
        }

        let change = deviceDeltaY > 0 ? 0.1 : -0.1
        return min(max(current + change, minimum), maximum)
    }
}

struct TranslationRequestGate {
    private(set) var currentID: UUID?

    mutating func begin() -> UUID {
        let id = UUID()
        currentID = id
        return id
    }

    mutating func cancel() {
        currentID = nil
    }

    func accepts(_ id: UUID) -> Bool {
        currentID == id
    }
}

func textChunks(_ text: String, maximumLength: Int) -> [String] {
    guard maximumLength > 0 else { return [] }
    var chunks: [String] = []
    var remaining = text[...]
    while !remaining.isEmpty {
        let tentativeEnd = remaining.index(
            remaining.startIndex,
            offsetBy: min(maximumLength, remaining.count),
            limitedBy: remaining.endIndex
        ) ?? remaining.endIndex
        if tentativeEnd == remaining.endIndex {
            let chunk = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { chunks.append(String(chunk)) }
            break
        }
        let candidate = remaining[..<tentativeEnd]
        let preferredBreak = candidate.lastIndex(where: { $0 == "\n" || $0 == " " || $0 == "." || $0 == "。" })
        let splitIndex = preferredBreak.map { remaining.index(after: $0) } ?? tentativeEnd
        let chunk = remaining[..<splitIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        if !chunk.isEmpty { chunks.append(String(chunk)) }
        remaining = remaining[splitIndex...].drop(while: { $0.isWhitespace })
    }
    return chunks
}

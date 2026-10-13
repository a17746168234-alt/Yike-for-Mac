import SwiftUI

/// Animates presentation only; copying, history and speech retain the full result.
struct TypewriterTranslationText: View {
    let text: String
    let highlightedText: AttributedString
    let isSpeaking: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibleText = ""
    @State private var finished = false

    var body: some View {
        Text(finished || reduceMotion || isSpeaking ? highlightedText : AttributedString(visibleText))
            .accessibilityLabel(text)
            .task(id: text) {
                visibleText = ""
                finished = false
                guard !reduceMotion, !text.isEmpty, !isSpeaking else {
                    finished = true
                    return
                }
                let characters = Array(text)
                // Reveal short results character by character; cap long results at ~1.5s.
                let batch = max(1, Int(ceil(Double(characters.count) / 75)))
                var offset = 0
                while offset < characters.count {
                    guard !Task.isCancelled else { return }
                    let end = min(offset + batch, characters.count)
                    visibleText.append(contentsOf: characters[offset..<end])
                    offset = end
                    if offset < characters.count {
                        do { try await Task.sleep(nanoseconds: 20_000_000) }
                        catch { return }
                    }
                }
                finished = true
            }
    }
}

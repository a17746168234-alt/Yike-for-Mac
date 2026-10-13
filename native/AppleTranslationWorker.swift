import SwiftUI
import Translation

@available(macOS 15.0, *)
struct AppleTranslationWorker: View {
    @ObservedObject var model: TranslatorViewModel

    var body: some View {
        Group {
            if let request = model.appleImageTranslationRequest {
                AppleRequestSession(source: request.source, target: request.target) { session in
                    await model.completeAppleImageTranslation(using: session, request: request)
                }
                .id(request.id)
            } else if let request = model.appleTranslationRequest {
                AppleRequestSession(source: request.source, target: request.target) { session in
                    await model.completeAppleTranslation(using: session, request: request)
                }
                .id(request.id)
            }
        }
    }
}

/// Each request owns a fresh session; no onChange hand-off can miss an initial
/// request or reuse a cancelled session when the language pair stays the same.
@available(macOS 15.0, *)
struct AppleRequestSession: View {
    let source: String
    let target: String
    let translate: (TranslationSession) async -> Void

    private var configuration: TranslationSession.Configuration? {
        guard let sourceID = appleTranslationLocales[source],
              let targetID = appleTranslationLocales[target] else { return nil }
        return TranslationSession.Configuration(
            source: Locale.Language(identifier: sourceID),
            target: Locale.Language(identifier: targetID)
        )
    }

    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .translationTask(configuration) { session in
                await translate(session)
            }
    }
}

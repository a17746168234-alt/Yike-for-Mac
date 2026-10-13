import SwiftUI
import AppKit
import Speech
import AVFoundation
import Translation
import Vision
import NaturalLanguage
import UniformTypeIdentifiers
import ApplicationServices
import Carbon.HIToolbox

enum TranslationEngine: String, CaseIterable, Identifiable {
    case apple
    case deepl
    case sharedDeepL

    var id: String { rawValue }

    var name: String {
        switch self {
        case .apple: return "Apple 系统翻译"
        case .deepl: return "DeepL（个人接入）"
        case .sharedDeepL: return "DeepL 高质量翻译"
        }
    }

    var shortName: String {
        switch self {
        case .apple: return "Apple 翻译"
        case .deepl: return "DeepL"
        case .sharedDeepL: return "DeepL"
        }
    }
}

struct AppleTranslationRequest: Identifiable, Equatable {
    let id: UUID
    let text: String
    let originalText: String
    let source: String
    let target: String
    let glossaryMap: [String: String]
}

struct DeepLTranslationPayload: Decodable {
    struct Item: Decodable {
        let text: String
    }

    let translations: [Item]
}

struct TranslationHistory: Identifiable, Codable {
    let id: UUID
    let original: String
    let result: String
    let source: String
    let target: String
    var date: Date
    var engine: String
    var isPinned: Bool

    init(id: UUID, original: String, result: String, source: String, target: String,
         date: Date = Date(), engine: String = "", isPinned: Bool = false) {
        self.id = id
        self.original = original
        self.result = result
        self.source = source
        self.target = target
        self.date = date
        self.engine = engine
        self.isPinned = isPinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        original = try container.decode(String.self, forKey: .original)
        result = try container.decode(String.self, forKey: .result)
        source = try container.decode(String.self, forKey: .source)
        target = try container.decode(String.self, forKey: .target)
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        engine = try container.decodeIfPresent(String.self, forKey: .engine) ?? ""
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, original, result, source, target, date, engine, isPinned
    }
}

struct ImageTranslationHistory: Identifiable, Codable {
    let id: UUID
    var date: Date
    var source: String
    var target: String
    var engine: String
    var style: ImageTranslationRenderStyle
    var sourceFileName: String
    var translatedFileName: String
    var originalText: String
    var translatedText: String
    var blocks: [EditableImageTranslationBlock]
}

struct GlossaryEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var source: String
    var target: String
    var sourceLanguage: String
    var targetLanguage: String
}

enum NoticeKind {
    case success
    case info
    case error

    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: return Color(red: 0.16, green: 0.65, blue: 0.42)
        case .info: return Color(red: 0.08, green: 0.45, blue: 0.96)
        case .error: return Color.orange
        }
    }

    var title: String {
        switch self {
        case .success: return "已完成"
        case .info: return "提示"
        case .error: return "需要注意"
        }
    }
}

enum NoticeAction {
    case openAccessibilitySettings
    case openSpeechRecognitionSettings
    case openMicrophoneSettings

    var buttonTitle: String { "打开系统设置" }

    var url: URL? {
        switch self {
        case .openAccessibilitySettings:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .openSpeechRecognitionSettings:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        case .openMicrophoneSettings:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    func open() {
        if let url { NSWorkspace.shared.open(url) }
    }
}

struct AppNotice {
    let kind: NoticeKind
    let message: String
    var action: NoticeAction? = nil
    var diagnostic: TranslationDiagnostic? = nil
    var retryVoiceModelDownload = false

    static func translation(_ diagnostic: TranslationDiagnostic) -> Self {
        Self(kind: .error, message: diagnostic.message, diagnostic: diagnostic)
    }
}

struct DeepLUsagePayload: Decodable {
    let characterCount: Int
    let characterLimit: Int

    enum CodingKeys: String, CodingKey {
        case characterCount = "character_count"
        case characterLimit = "character_limit"
    }

    var usedPercentText: String {
        guard characterLimit > 0 else { return "0" }
        return String(format: "%.1f", Double(characterCount) / Double(characterLimit) * 100)
    }
}

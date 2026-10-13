import AppKit
import Foundation

struct RecognizedImageBlock: Identifiable, Equatable, Codable {
    let id: UUID
    var text: String
    var boundingBox: CGRect
    var confidence: Float?
    var candidates: [String]?
    var reviewed: Bool?

    var needsReview: Bool { reviewed != true && (confidence ?? 1) < 0.85 }

    init(id: UUID = UUID(), text: String, boundingBox: CGRect,
         confidence: Float? = nil, candidates: [String]? = nil, reviewed: Bool? = nil) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.candidates = candidates
        self.reviewed = reviewed
    }
}

struct AppleImageTranslationRequest: Identifiable, Equatable {
    let id = UUID()
    let blocks: [RecognizedImageBlock]
    let source: String
    let target: String
}

struct PopupAppleTranslationRequest: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let originalText: String
    let source: String
    let target: String
    let glossaryMap: [String: String]
}

enum ImageTranslationRenderStyle: String, CaseIterable, Identifiable, Codable {
    case natural
    case contrast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .natural: return "自然融入"
        case .contrast: return "高对比"
        }
    }

    var icon: String {
        switch self {
        case .natural: return "wand.and.stars"
        case .contrast: return "rectangle.inset.filled"
        }
    }
}

enum ImageOverlayTextColor: String, CaseIterable, Identifiable, Codable {
    case automatic
    case black
    case white
    case blue
    case red

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "自动"
        case .black: return "黑色"
        case .white: return "白色"
        case .blue: return "蓝色"
        case .red: return "红色"
        }
    }

    func resolved(automaticColor: NSColor) -> NSColor {
        switch self {
        case .automatic: return automaticColor
        case .black: return .black
        case .white: return .white
        case .blue: return NSColor.systemBlue
        case .red: return NSColor.systemRed
        }
    }
}

enum ImageOverlayTextAlignment: String, CaseIterable, Identifiable, Codable {
    case automatic
    case left
    case center
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "自动"
        case .left: return "左"
        case .center: return "中"
        case .right: return "右"
        }
    }

    func resolved(automaticAlignment: NSTextAlignment) -> NSTextAlignment {
        switch self {
        case .automatic: return automaticAlignment
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }
}

struct EditableImageTranslationBlock: Identifiable, Equatable, Codable {
    let id: UUID
    var originalText: String
    var translatedText: String
    var boundingBox: CGRect
    var fontScale: Double
    var textColor: ImageOverlayTextColor
    var alignment: ImageOverlayTextAlignment

    init(
        id: UUID = UUID(),
        originalText: String,
        translatedText: String,
        boundingBox: CGRect,
        fontScale: Double = 1,
        textColor: ImageOverlayTextColor = .automatic,
        alignment: ImageOverlayTextAlignment = .automatic
    ) {
        self.id = id
        self.originalText = originalText
        self.translatedText = translatedText
        self.boundingBox = boundingBox
        self.fontScale = fontScale
        self.textColor = textColor
        self.alignment = alignment
    }
}

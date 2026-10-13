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

@MainActor
final class TranslatorViewModel: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    static let shared = TranslatorViewModel()

    @Published var sourceText = "" {
        didSet {
            if sourceText != lastRecognizedText { detectedVoiceLanguage = nil }
        }
    }
    @Published var translatedText = ""
    @Published var sourceLanguage = "auto"
    @Published var targetLanguage = "zh-CN"
    @Published var isLoading = false
    @Published var translationProgress = "正在翻译…"
    @Published var popupTranslationProgress = "正在翻译…"
    @Published var ocrSummary = ""
    private var ocrTask: Task<Void, Never>?
    private var recognitionGate = TranslationRequestGate()
    private var imageRequestGate = TranslationRequestGate()
    @Published var notice: AppNotice?
    @Published private(set) var deepLUsage: DeepLUsagePayload?
    @Published var historyRecordingEnabled = true
    @Published var imageHistoryRecordingEnabled = true
    @Published var copyLabel = "复制译文"
    @Published var isListening = false
    @Published var deepLKeyFeedback: AppNotice?
    @Published var showVoiceModelDownload = false
    @Published private(set) var detectedVoiceLanguage: String?
    private let localSpeech = LocalSpeechRecognizer()
    private let partialSpeech = LocalSpeechRecognizer()
    private var partialVoiceTask: Task<Void, Never>?
    private var voiceRecorder: AVAudioRecorder?
    private var voiceAudioURL: URL?
    private var voiceOperation: Task<Void, Never>?
    private var voiceMeterTask: Task<Void, Never>?
    private var voiceSession: UUID?
    private var hasInputTap = false
    private var keyFeedbackTask: Task<Void, Never>?
    @Published private(set) var isVoiceProcessing = false
    @Published private(set) var microphoneLevel: Float = 0
    @Published private(set) var voiceInputStatus = "正在聆听…"
    @Published private(set) var voiceSilenceCountdown: Int?
    @Published var history: [TranslationHistory] = []
    @Published private(set) var imageHistory: [ImageTranslationHistory] = []
    @Published var showSharedAccount = false
    @Published var selectedEngine: TranslationEngine = .apple
    @Published var appleTranslationRequest: AppleTranslationRequest? {
        didSet {
            if let request = appleTranslationRequest { armAppleWatchdog(id: request.id) }
            else if appleImageTranslationRequest == nil { appleWatchdog.cancel() }
        }
    }
    @Published var appleImageTranslationRequest: AppleImageTranslationRequest? {
        didSet {
            if let request = appleImageTranslationRequest { armAppleWatchdog(id: request.id) }
            else if appleTranslationRequest == nil { appleWatchdog.cancel() }
        }
    }
    @Published private(set) var popupAppleTranslationRequest: PopupAppleTranslationRequest? {
        didSet {
            if let request = popupAppleTranslationRequest { armAppleWatchdog(id: request.id, popup: true) }
            else { popupAppleWatchdog.cancel() }
        }
    }
    @Published private(set) var popupSourceText = ""
    @Published private(set) var popupTranslatedText = ""
    @Published private(set) var popupSourceLanguage = "en"
    @Published private(set) var popupTargetLanguage = "zh-CN"
    @Published private(set) var popupIsLoading = false
    @Published private(set) var popupNotice: AppNotice?
    @Published private(set) var hasDeepLKey = false
    @Published private(set) var isRecognizingImage = false
    @Published private(set) var isCapturingRegion = false
    @Published private(set) var screenCaptureCountdown = 0
    @Published private(set) var sourceImage: NSImage?
    @Published private(set) var translatedImage: NSImage?
    @Published private(set) var imageRenderStyle: ImageTranslationRenderStyle = .natural
    @Published private(set) var imageActionLabel = "复制图片"
    @Published private(set) var isSpeakingResult = false
    @Published private(set) var isResultSpeechPaused = false
    @Published private(set) var isPreparingSpeech = false
    @Published private(set) var speechStatusMessage: String?
    @Published var onlineVoicePersona: OnlineVoicePersona = .female
    @Published var onlineSpeechRatePercent = -6
    @Published private(set) var speechHighlightedSentenceIndex = -1
    @Published var glossary: [GlossaryEntry] = []
    @Published var isEditingImageOCR = false
    @Published private(set) var isInitialImageOCRReview = false
    @Published private(set) var editableImageBlocks: [EditableImageTranslationBlock] = []
    @Published private(set) var speechCacheBytes: Int64 = 0
    @Published var popupPinned = false

    private let historyKey = "yijian.translation.history"
    private let engineKey = "yijian.translation.engine"
    private let imageRenderStyleKey = "yijian.image.translation.render-style"
    private let historyEnabledKey = "yijian.history.recording.enabled"
    private let imageHistoryKey = "yijian.image.translation.history"
    private let imageHistoryEnabledKey = "yijian.image.history.recording.enabled"
    private let glossaryKey = "yijian.translation.glossary"
    private let voicePersonaKey = "yijian.online-speech.voice-persona"
    private let speechRateKey = "yijian.online-speech.rate-percent"
    private let audioEngine = AVAudioEngine()
    private let onlineSpeechService = OnlineTTSService()
    private var onlineSpeechRate: String {
        onlineSpeechRatePercent > 0 ? "+\(onlineSpeechRatePercent)%" : "\(onlineSpeechRatePercent)%"
    }
    private var resultAudioPlayer: AVAudioPlayer?
    private let fallbackSpeechSynthesizer = AVSpeechSynthesizer()
    private var speechTask: Task<Void, Never>?
    private var speechHighlightTask: Task<Void, Never>?
    private var speechAudioURL: URL?
    private var speechPreloadTask: Task<URL?, Never>?
    private let appleWatchdog = TranslationWatchdog()
    private let popupAppleWatchdog = TranslationWatchdog()
    private var translationTask: Task<Void, Never>?
    private var translationRequestGate = TranslationRequestGate()
    private var imageTranslationTask: Task<Void, Never>?
    private var popupTranslationTask: Task<Void, Never>?
    private var speechPreloadKey: String?
    private var deepLAPIKey = ""
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTask: Task<Void, Never>?
    private var didLoadKeyAfterLaunch = false
    private var autoSubmitAfterVoice = false
    private var speechBaseText = ""
    private var speechSentences: [String] = []
    private var lastRecognizedText = ""
    private var lastSelectionRequestAt = Date.distantPast
    private var lastSelectionProcessID: pid_t?
    private var recognizedImageBlocks: [RecognizedImageBlock] = []
    private var imageBlockTranslations: [String] = []
    private var pendingImageSourceLanguage = "en"
    private var pendingImageTargetLanguage = "zh-CN"
    private var currentImageHistoryID: UUID?
    private lazy var selectionPanelController = SelectionTranslationPanelController()

    private struct PasteboardItemSnapshot {
        let values: [(NSPasteboard.PasteboardType, Data)]
    }

    override init() {
        super.init()
        fallbackSpeechSynthesizer.delegate = self
        trimOnlineSpeechCache()
        if let value = UserDefaults.standard.string(forKey: engineKey),
           let engine = TranslationEngine(rawValue: value) {
            selectedEngine = engine
        }
        if let value = UserDefaults.standard.string(forKey: imageRenderStyleKey),
           let style = ImageTranslationRenderStyle(rawValue: value) {
            imageRenderStyle = style
        }
        if UserDefaults.standard.object(forKey: historyEnabledKey) != nil {
            historyRecordingEnabled = UserDefaults.standard.bool(forKey: historyEnabledKey)
        }
        if UserDefaults.standard.object(forKey: imageHistoryEnabledKey) != nil {
            imageHistoryRecordingEnabled = UserDefaults.standard.bool(forKey: imageHistoryEnabledKey)
        }
        if let value = UserDefaults.standard.string(forKey: voicePersonaKey) {
            let persona: OnlineVoicePersona = (value == "male" || value == "youthfulMale") ? .male : .female
            onlineVoicePersona = persona
            UserDefaults.standard.set(persona.rawValue, forKey: voicePersonaKey)
        }
        if UserDefaults.standard.object(forKey: speechRateKey) != nil {
            onlineSpeechRatePercent = min(30, max(-30, UserDefaults.standard.integer(forKey: speechRateKey)))
        }
        if let data = UserDefaults.standard.data(forKey: glossaryKey),
           let items = try? JSONDecoder().decode([GlossaryEntry].self, from: data) {
            glossary = items
        }
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let items = try? JSONDecoder().decode([TranslationHistory].self, from: data) {
            history = items
        }
        if let data = UserDefaults.standard.data(forKey: imageHistoryKey),
           let items = try? JSONDecoder().decode([ImageTranslationHistory].self, from: data) {
            imageHistory = Array(items.filter { item in
                FileManager.default.fileExists(atPath: imageHistoryDirectory.appendingPathComponent(item.sourceFileName).path)
                    && FileManager.default.fileExists(atPath: imageHistoryDirectory.appendingPathComponent(item.translatedFileName).path)
            }.prefix(10))
        }
        refreshSpeechCacheSize()
    }

    func loadKeyAfterLaunch() {
        guard !didLoadKeyAfterLaunch else { return }
        didLoadKeyAfterLaunch = true
        deepLAPIKey = SecureKeyStore.loadDeepLKey()
        hasDeepLKey = !deepLAPIKey.isEmpty
        if hasDeepLKey { Task { await fetchDeepLUsage() } }
    }

    private func armAppleWatchdog(id: UUID, popup: Bool = false, seconds: Double = 45, stage: String = "启动系统翻译") {
        let watchdog = popup ? popupAppleWatchdog : appleWatchdog
        watchdog.arm(seconds: seconds) { [weak self] in
            guard let self else { return }
            if popup {
                guard self.popupAppleTranslationRequest?.id == id else { return }
                self.popupAppleTranslationRequest = nil
                self.popupIsLoading = false
                self.popupNotice = .translation(.stalled(stage: stage))
            } else {
                guard self.appleTranslationRequest?.id == id || self.appleImageTranslationRequest?.id == id else { return }
                self.translationRequestGate.cancel()
                self.imageRequestGate.cancel()
                self.appleTranslationRequest = nil
                self.appleImageTranslationRequest = nil
                self.isLoading = false
                self.notice = .translation(.stalled(stage: stage))
            }
        }
    }

    func retryPopupTranslation() { translatePopup() }

    private func setError(_ message: String, action: NoticeAction? = nil) {
        notice = AppNotice(kind: .error, message: message, action: action)
    }

    private func setSuccess(_ message: String) {
        notice = AppNotice(kind: .success, message: message)
    }

    private func setInfo(_ message: String, action: NoticeAction? = nil) {
        notice = AppNotice(kind: .info, message: message, action: action)
    }

    var sourceName: String { languageName(sourceLanguage) }
    var targetName: String { languageName(targetLanguage) }
    var canTranslate: Bool { !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading && !isListening && !isVoiceProcessing }
    var hasImageTranslation: Bool { sourceImage != nil }
    var canEditImageSourceText: Bool {
        sourceImage != nil && !recognizedImageBlocks.isEmpty && !isRecognizingImage
    }

    func translateSelectedText(from processID: pid_t?) {
        let now = Date()
        if processID == lastSelectionProcessID,
           now.timeIntervalSince(lastSelectionRequestAt) < 0.45 {
            return
        }
        lastSelectionRequestAt = now
        lastSelectionProcessID = processID

        guard let processID else {
            showGlobalShortcutError("没有找到当前使用的软件，请重新选中文字后再试")
            return
        }

        if let capture = accessibilitySelection(from: processID), !capture.text.isEmpty {
            useSelectedTextAndTranslate(capture.text, anchor: capture.anchor, sourceProcessID: processID)
            return
        }

        copySelectedTextFromFrontmostApp { [weak self] selectedText in
            guard let self else { return }
            guard let selectedText, !selectedText.isEmpty else {
                self.showGlobalShortcutError("没有读取到选中的文字。请确认已选中文字；如果刚打开辅助功能权限，请完全退出“Yike”后重新打开")
                return
            }
            self.useSelectedTextAndTranslate(selectedText, anchor: NSEvent.mouseLocation, sourceProcessID: processID)
        }
    }

    func requestGlobalShortcutPermission() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
            setSuccess("划词翻译已可使用：选中文字后按 \(globalShortcutDescription)")
        } else {
            setInfo("请在系统设置 → 隐私与安全性 → 辅助功能中允许“Yike”", action: .openAccessibilitySettings)
        }
    }

    private func accessibilitySelection(from processID: pid_t) -> SelectedTextCapture? {
        let application = AXUIElementCreateApplication(processID)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }

        let focusedElement = unsafeBitCast(focusedValue, to: AXUIElement.self)
        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        ) == .success else { return nil }
        guard let text = (selectedValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return SelectedTextCapture(text: text, anchor: selectionAnchor(for: focusedElement) ?? NSEvent.mouseLocation)
    }

    private func selectionAnchor(for element: AXUIElement) -> CGPoint? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success,
        let rangeValue,
        CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        ) == .success,
        let boundsValue,
        CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }

        var accessibilityRect = CGRect.zero
        guard AXValueGetValue(
            unsafeBitCast(boundsValue, to: AXValue.self),
            .cgRect,
            &accessibilityRect
        ) else { return nil }

        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let bounds = CGRect(x: accessibilityRect.minX, y: primaryTop - accessibilityRect.maxY,
                            width: accessibilityRect.width, height: accessibilityRect.height)
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(bounds) }) else { return nil }
        return CGPoint(x: bounds.midX, y: bounds.minY)
    }

    private func copySelectedTextFromFrontmostApp(completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let snapshot = pasteboardSnapshot(pasteboard)
        let marker = "fanyi-selection-\(UUID().uuidString)"
        pasteboard.clearContents()
        pasteboard.setString(marker, forType: .string)

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false) else {
            restorePasteboard(snapshot, to: pasteboard)
            completion(nil)
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            let copied = pasteboard.string(forType: .string)
            self?.restorePasteboard(snapshot, to: pasteboard)
            completion(copied == marker ? nil : copied?.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func pasteboardSnapshot(_ pasteboard: NSPasteboard) -> [PasteboardItemSnapshot] {
        (pasteboard.pasteboardItems ?? []).map { item in
            PasteboardItemSnapshot(values: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    private func restorePasteboard(_ snapshot: [PasteboardItemSnapshot], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = snapshot.map { snapshotItem -> NSPasteboardItem in
            let item = NSPasteboardItem()
            snapshotItem.values.forEach { item.setData($0.1, forType: $0.0) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    private func useSelectedTextAndTranslate(_ text: String, anchor: CGPoint, sourceProcessID: pid_t) {
        cancelPopupVoiceInput()
        let limitedText = String(text.prefix(maxSourceCharacters))
        popupSourceText = limitedText
        popupSourceLanguage = detectSupportedLanguage(in: limitedText)
        popupTargetLanguage = popupSourceLanguage == "en" ? "zh-CN" : "en"
        popupTranslatedText = ""
        popupNotice = nil
        selectionPanelController.show(model: self, anchor: anchor, sourceProcessID: sourceProcessID)
        translatePopup()
    }

    private func showGlobalShortcutError(_ message: String) {
        popupTranslationTask?.cancel()
        popupTranslationTask = nil
        popupAppleTranslationRequest = nil
        popupSourceText = ""
        popupTranslatedText = ""
        popupIsLoading = false
        popupNotice = AppNotice(kind: .error, message: message)
        selectionPanelController.show(model: self, anchor: NSEvent.mouseLocation, sourceProcessID: nil)
    }

    func setPopupSourceLanguage(_ language: String) {
        guard language != popupTargetLanguage else { return }
        popupSourceLanguage = language
        popupTranslatedText = ""
        translatePopup()
    }

    func setPopupTargetLanguage(_ language: String) {
        guard language != popupSourceLanguage else { return }
        popupTargetLanguage = language
        popupTranslatedText = ""
        translatePopup()
    }

    private func translatePopup() {
        let cleanText = popupSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }
        popupTranslationTask?.cancel()
        popupTranslationTask = nil
        popupAppleTranslationRequest = nil
        popupTranslatedText = ""
        popupNotice = nil
        popupIsLoading = true
        popupTranslationProgress = "正在检查翻译服务…"

        let source = popupSourceLanguage
        let target = popupTargetLanguage
        let prepared = glossaryPreparedText(cleanText, source: source, target: target)

        switch selectedEngine {
        case .apple:
            if #available(macOS 15.0, *) {
                let request = PopupAppleTranslationRequest(
                    text: prepared.0,
                    originalText: cleanText,
                    source: source,
                    target: target,
                    glossaryMap: prepared.1
                )
                popupAppleTranslationRequest = request
            } else {
                popupIsLoading = false
                popupNotice = .translation(.appleSystemRequired)
            }
        case .deepl, .sharedDeepL:
            guard selectedEngine == .sharedDeepL ? SharedTrialAccount.shared.isSignedIn : hasDeepLKey else {
                popupIsLoading = false
                popupNotice = selectedEngine == .sharedDeepL ? AppNotice(kind: .info, message: "请在设置的“账号与安全”中注册或登录，领取公共体验额度。") : .translation(.missingDeepLKey)
                return
            }
            popupTranslationTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let results = try await self.deepLTranslations(for: [prepared.0], source: source, target: target)
                    guard !Task.isCancelled, let result = results.first else { return }
                    self.finishPopupTranslation(
                        result,
                        original: cleanText,
                        source: source,
                        target: target,
                        glossaryMap: prepared.1
                    )
                    Task { await self.refreshSelectedEngineUsage() }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.showPopupTranslationError(error, engine: .deepl)
                }
            }
        }
    }

    @available(macOS 15.0, *)
    func completePopupAppleTranslation(using session: TranslationSession, request: PopupAppleTranslationRequest) async {
        guard popupAppleTranslationRequest?.id == request.id else { return }
        do {
            try await AppleLanguagePreparation.prepare(session, source: request.source, target: request.target) { status in
                if self.popupAppleTranslationRequest?.id == request.id {
                    self.popupTranslationProgress = status
                    self.armAppleWatchdog(id: request.id, popup: true, seconds: 300, stage: "准备语言包")
                }
            }
            guard popupAppleTranslationRequest?.id == request.id else { return }
            armAppleWatchdog(id: request.id, popup: true, seconds: 90, stage: "翻译文字")
            let response = try await session.translate(request.text)
            guard popupAppleTranslationRequest?.id == request.id else { return }
            finishPopupTranslation(
                response.targetText,
                original: request.originalText,
                source: request.source,
                target: request.target,
                glossaryMap: request.glossaryMap
            )
        } catch {
            guard popupAppleTranslationRequest?.id == request.id else { return }
            showPopupTranslationError(error, engine: .apple)
        }
    }

    private func finishPopupTranslation(
        _ result: String,
        original: String,
        source: String,
        target: String,
        glossaryMap: [String: String]
    ) {
        popupTranslationTask = nil
        popupAppleTranslationRequest = nil
        popupTranslatedText = restoreGlossary(in: result, replacements: glossaryMap)
        popupIsLoading = false
        popupNotice = nil
        saveHistory(original: original, result: popupTranslatedText, source: source, target: target)
    }

    private func showPopupTranslationError(_ error: Error, engine: TranslationDiagnostic.Engine) {
        popupTranslationTask = nil
        popupAppleTranslationRequest = nil
        popupIsLoading = false
        popupNotice = error is TrialServiceError ? AppNotice(kind: .error, message: error.localizedDescription) : .translation(.explain(error, engine: engine))
    }

    func setEngine(_ engine: TranslationEngine) {
        cancelTranslation()
        popupTranslationTask?.cancel()
        popupAppleTranslationRequest = nil
        popupIsLoading = false
        selectedEngine = engine
        UserDefaults.standard.set(engine.rawValue, forKey: engineKey)
        notice = nil
    }

    func cancelTranslation() {
        translationTask?.cancel()
        imageTranslationTask?.cancel()
        translationTask = nil
        imageTranslationTask = nil
        translationRequestGate.cancel()
        imageRequestGate.cancel()
        appleTranslationRequest = nil
        appleImageTranslationRequest = nil
        isLoading = false
        notice = nil
    }

    func addGlossaryEntry(source: String, target: String, sourceLanguage: String, targetLanguage: String) {
        let cleanSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSource.isEmpty, !cleanTarget.isEmpty, sourceLanguage != targetLanguage else { return }
        if let index = glossary.firstIndex(where: {
            $0.source.caseInsensitiveCompare(cleanSource) == .orderedSame
                && $0.sourceLanguage == sourceLanguage
                && $0.targetLanguage == targetLanguage
        }) {
            glossary[index].target = cleanTarget
        } else {
            glossary.append(GlossaryEntry(
                source: cleanSource,
                target: cleanTarget,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            ))
        }
        persistGlossary()
    }

    func deleteGlossaryEntries(at offsets: IndexSet) {
        glossary.remove(atOffsets: offsets)
        persistGlossary()
    }

    private func persistGlossary() {
        if let data = try? JSONEncoder().encode(glossary) {
            UserDefaults.standard.set(data, forKey: glossaryKey)
        }
    }

    private func glossaryPreparedText(_ text: String, source: String, target: String) -> (String, [String: String]) {
        let matching = glossary
            .filter { $0.sourceLanguage == source && $0.targetLanguage == target }
            .sorted { $0.source.count > $1.source.count }
        guard !matching.isEmpty else { return (text, [:]) }

        var value = text
        var replacements: [String: String] = [:]
        for (index, entry) in matching.enumerated() {
            let token = "ZXQGLOSSARY\(index)QXZ"
            let replaced = value.replacingOccurrences(
                of: entry.source,
                with: token,
                options: [.caseInsensitive],
                range: nil
            )
            if replaced != value {
                value = replaced
                replacements[token] = entry.target
            }
        }
        return (value, replacements)
    }

    private func restoreGlossary(in text: String, replacements: [String: String]) -> String {
        var value = text
        for (token, replacement) in replacements {
            value = value.replacingOccurrences(of: token, with: replacement, options: [.caseInsensitive])
            let flexibleToken = token.map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "\\s*")
            if let expression = try? NSRegularExpression(pattern: flexibleToken, options: [.caseInsensitive]) {
                let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
                value = expression.stringByReplacingMatches(
                    in: value,
                    range: fullRange,
                    withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
                )
            }
        }
        return value
    }

    @discardableResult
    func saveDeepLKey(_ value: String) -> Bool {
        keyFeedbackTask?.cancel()
        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try SecureKeyStore.saveDeepLKey(cleanValue)
        } catch {
            deepLKeyFeedback = AppNotice(kind: .error, message: "密钥保存失败，请重试：\(error.localizedDescription)")
            setError("无法保存到系统钥匙串：\(error.localizedDescription)")
            return false
        }
        deepLAPIKey = cleanValue
        hasDeepLKey = !cleanValue.isEmpty
        if hasDeepLKey { setEngine(.deepl) }
        deepLUsage = nil
        if hasDeepLKey {
            Task { await self.refreshSelectedEngineUsage() }
        }
        keyFeedbackTask?.cancel()
        deepLKeyFeedback = AppNotice(kind: .success, message: hasDeepLKey ? "DeepL 密钥已保存成功，已切换到 DeepL" : "DeepL 密钥已移除")
        keyFeedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.deepLKeyFeedback = nil
        }
        return true
    }

    func editTranslatedText(_ value: String) {
        guard value != translatedText else { return }
        cancelSpeechPreload()
        stopOnlineSpeech()
        translatedText = value
        speechStatusMessage = nil
        copyLabel = "复制译文"
    }

    func setSourceLanguage(_ value: String) {
        cancelTranslation()
        if isListening || isVoiceProcessing { cancelVoiceInput() }
        sourceLanguage = value
        if targetLanguage == value {
            targetLanguage = value == "zh-CN" ? "en" : "zh-CN"
        }
    }

    func setTargetLanguage(_ value: String) {
        cancelTranslation()
        targetLanguage = value
        if sourceLanguage == value {
            setSourceLanguage(value == "zh-CN" ? "en" : "zh-CN")
        }
    }

    func swapLanguages() {
        guard !hasImageTranslation else { return }
        cancelTranslation()
        if isListening || isVoiceProcessing { cancelVoiceInput() }
        cancelSpeechPreload()
        if sourceLanguage == "auto" {
            sourceLanguage = detectSupportedLanguage(in: sourceText)
        }
        (sourceLanguage, targetLanguage) = (targetLanguage, sourceLanguage)
        (sourceText, translatedText) = (translatedText, sourceText)
        notice = nil
        preGenerateResultSpeech()
    }

    func clear() {
        ocrTask?.cancel()
        ocrTask = nil
        recognitionGate.cancel()
        imageRequestGate.cancel()
        if isListening || isVoiceProcessing { cancelVoiceInput() }
        cancelSpeechPreload()
        stopOnlineSpeech()
        translationTask?.cancel()
        translationTask = nil
        translationRequestGate.cancel()
        imageTranslationTask?.cancel()
        imageTranslationTask = nil
        isLoading = false
        isRecognizingImage = false
        isCapturingRegion = false
        screenCaptureCountdown = 0
        isEditingImageOCR = false
        isInitialImageOCRReview = false
        sourceText = ""
        translatedText = ""
        sourceImage = nil
        translatedImage = nil
        recognizedImageBlocks = []
        imageBlockTranslations = []
        editableImageBlocks = []
        currentImageHistoryID = nil
        appleImageTranslationRequest = nil
        appleTranslationRequest = nil
        notice = nil
    }

    @Published var pendingImageCrop: ImageCropItem?
    func recognizeAndTranslateImage(at url: URL) {
        guard !isRecognizingImage, !isLoading, pendingImageCrop == nil else { return }
        isRecognizingImage = true
        Task {
            do {
                let item = try await Task.detached(priority: .userInitiated) { try ImageCropItem(url: url) }.value
                isRecognizingImage = false
                pendingImageCrop = item
            } catch {
                isRecognizingImage = false
                setError(error.localizedDescription)
            }
        }
    }

    func finishImageCrop(_ item: ImageCropItem, selection: CGRect?) {
        guard !isRecognizingImage else { return }
        pendingImageCrop = nil
        isRecognizingImage = true
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    let image = try item.croppedImage(selection: selection)
                    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Yike-Crop-\(UUID().uuidString).png")
                    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                        throw ImageImportError.unreadable
                    }
                    try data.write(to: destination)
                    return destination
                }.value
                // Present OCR review only after SwiftUI finishes dismissing the crop sheet.
                try? await Task.sleep(for: .milliseconds(300))
                beginImageRecognition(at: url, deleteAfterUse: true)
            } catch {
                isRecognizingImage = false
                setError("保存裁剪图片失败：\(error.localizedDescription)")
            }
        }
    }

    func captureScreenRegionAndTranslate() {
        guard !isCapturingRegion, !isRecognizingImage, !isLoading else { return }
        isCapturingRegion = true
        screenCaptureCountdown = 3
        notice = AppNotice(kind: .info, message: "请切换到目标窗口，3 秒后开始框选")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacTranslation-Capture-\(UUID().uuidString).png")

        Task {
            for remaining in stride(from: 3, through: 1, by: -1) {
                screenCaptureCountdown = remaining
                notice = AppNotice(kind: .info, message: "请切换到目标窗口，\(remaining) 秒后开始框选")
                try? await Task.sleep(for: .seconds(1))
            }
            screenCaptureCountdown = 0
            notice = AppNotice(kind: .info, message: "拖动选择要翻译的区域，按 Esc 可取消")
            NSApp.hide(nil)
            try? await Task.sleep(for: .milliseconds(220))

            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    process.arguments = ["-i", "-x", destination.path]
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0,
                          FileManager.default.fileExists(atPath: destination.path) else {
                        throw ImageRecognitionError.unreadableImage
                    }
                    return .success(destination)
                } catch {
                    return .failure(error)
                }
            }.value
            restoreApplicationAfterScreenCapture()
            isCapturingRegion = false
            switch result {
            case .success(let url):
                beginImageRecognition(at: url, deleteAfterUse: true)
            case .failure:
                notice = nil // Region selection was normally cancelled with Esc.
                try? FileManager.default.removeItem(at: destination)
            }
        }
    }

    private func restoreApplicationAfterScreenCapture() {
        NSApp.unhide(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: {
            $0.level == .normal && $0.styleMask.contains(.titled)
        })?.makeKeyAndOrderFront(nil)
    }

    private func beginImageRecognition(at url: URL, deleteAfterUse: Bool) {
        clear()
        let requestID = recognitionGate.begin()
        isRecognizingImage = true
        ocrSummary = "正在检查方向、倾斜和文字对比度…"
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        ocrTask = Task {
            defer {
                if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
                if deleteAfterUse { try? FileManager.default.removeItem(at: url) }
            }
            do {
                let worker = Task.detached(priority: .userInitiated) { try OCRService.recognize(at: url) }
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, recognitionGate.accepts(requestID) else { return }
                sourceImage = NSImage(cgImage: result.image, size: NSSize(width: result.image.width, height: result.image.height))
                recognizedImageBlocks = result.blocks
                // Retain all regions. The review screen clearly blocks oversized requests instead of silently dropping text.
                sourceText = result.blocks.map(\.text).joined(separator: "\n")
                ocrSummary = (result.adjustments + ["\(result.blocks.count) 处文字", "\(result.blocks.filter(\.needsReview).count) 处建议检查"]).joined(separator: " · ")
                if result.blocks.isEmpty { ocrSummary = "未识别到文字，可使用“补框”手动添加。" }
                let detected = detectSupportedLanguage(in: sourceText)
                sourceLanguage = detected
                if targetLanguage == detected { targetLanguage = detected == "en" ? "zh-CN" : "en" }
                pendingImageSourceLanguage = detected
                pendingImageTargetLanguage = targetLanguage
                isRecognizingImage = false
                isInitialImageOCRReview = true
                isEditingImageOCR = true
                ocrTask = nil
            } catch {
                guard !Task.isCancelled, recognitionGate.accepts(requestID) else { return }
                isRecognizingImage = false
                ocrTask = nil
                setError(error.localizedDescription)
            }
        }
    }

    func imageOCRBlocksForEditing() -> [RecognizedImageBlock] {
        recognizedImageBlocks
    }

    func confirmImageOCRBlocks(_ blocks: [RecognizedImageBlock]) {
        let acceptedBlocks = blocks.compactMap { block -> RecognizedImageBlock? in
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            var edited = block
            edited.text = text
            return edited
        }
        guard !acceptedBlocks.isEmpty else {
            setError("识别文字不能为空")
            return
        }
        guard acceptedBlocks.map(\.text).joined(separator: "\n").count <= maxSourceCharacters else {
            setError("识别文字超过 5,000 字，请拆成多张图片或删除不需要的区域后重试。")
            return
        }
        recognizedImageBlocks = OCRDocument.ordered(acceptedBlocks)
        sourceText = recognizedImageBlocks.map(\.text).joined(separator: "\n")
        let effectiveSource = sourceLanguage == "auto" ? detectSupportedLanguage(in: sourceText) : sourceLanguage
        pendingImageSourceLanguage = effectiveSource
        pendingImageTargetLanguage = targetLanguage
        isInitialImageOCRReview = false
        isEditingImageOCR = false
        beginImageTranslation(source: pendingImageSourceLanguage, target: pendingImageTargetLanguage)
    }

    func cancelImageOCREditing() {
        isEditingImageOCR = false
        if isInitialImageOCRReview {
            isInitialImageOCRReview = false
            clear()
        }
    }

    func editImageSourceText() {
        guard canEditImageSourceText else { return }
        imageRequestGate.cancel()
        imageTranslationTask?.cancel()
        imageTranslationTask = nil
        appleImageTranslationRequest = nil
        isLoading = false
        pendingImageSourceLanguage = sourceLanguage == "auto" ? detectSupportedLanguage(in: sourceText) : sourceLanguage
        pendingImageTargetLanguage = targetLanguage
        isInitialImageOCRReview = false
        notice = nil
        isEditingImageOCR = true
    }

    private func detectSupportedLanguage(in text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let language = recognizer.dominantLanguage {
            switch language.rawValue {
            case "zh-Hans", "zh-Hant", "zh": return "zh-CN"
            case "ja": return "ja"
            case "ko": return "ko"
            case "en": return "en"
            case "de": return "de"
            case "fr": return "fr"
            default: break
            }
        }

        if text.unicodeScalars.contains(where: { (0xAC00...0xD7AF).contains(Int($0.value)) }) { return "ko" }
        if text.unicodeScalars.contains(where: {
            (0x3040...0x30FF).contains(Int($0.value)) || (0x31F0...0x31FF).contains(Int($0.value))
        }) { return "ja" }
        if text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains(Int($0.value)) }) { return "zh-CN" }
        return "en"
    }

    func use(_ item: TranslationHistory) {
        cancelTranslation()
        cancelSpeechPreload()
        sourceImage = nil
        translatedImage = nil
        recognizedImageBlocks = []
        imageBlockTranslations = []
        editableImageBlocks = []
        currentImageHistoryID = nil
        appleImageTranslationRequest = nil
        sourceText = item.original
        translatedText = item.result
        sourceLanguage = item.source
        targetLanguage = item.target
        notice = nil
        preGenerateResultSpeech()
    }

    func translate() {
        let cleanText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty, !isLoading, !isListening, !isVoiceProcessing else { return }

        let effectiveSource = sourceLanguage == "auto"
            ? ((sourceText == lastRecognizedText ? detectedVoiceLanguage : nil) ?? detectSupportedLanguage(in: cleanText))
            : sourceLanguage
        if sourceLanguage == "auto" {
            if effectiveSource == "en" { targetLanguage = "zh-CN" }
            else if effectiveSource == "zh-CN" { targetLanguage = "en" }
        }

        if sourceImage != nil, !recognizedImageBlocks.isEmpty {
            beginImageTranslation(source: effectiveSource, target: targetLanguage)
            return
        }

        cancelSpeechPreload()
        isLoading = true
        translationProgress = "正在检查翻译服务…"
        notice = nil
        appleImageTranslationRequest = nil

        translatedText = ""
        let prepared = glossaryPreparedText(cleanText, source: effectiveSource, target: targetLanguage)
        let target = targetLanguage
        translationTask?.cancel()
        let requestID = translationRequestGate.begin()

        switch selectedEngine {
        case .apple:
            if #available(macOS 15.0, *) {
                let request = AppleTranslationRequest(
                    id: requestID,
                    text: prepared.0,
                    originalText: cleanText,
                    source: effectiveSource,
                    target: target,
                    glossaryMap: prepared.1
                )
                appleTranslationRequest = request
            } else {
                translationRequestGate.cancel()
                isLoading = false
                notice = .translation(.appleSystemRequired)
            }
        case .deepl, .sharedDeepL:
            guard selectedEngine == .sharedDeepL ? SharedTrialAccount.shared.isSignedIn : hasDeepLKey else {
                translationRequestGate.cancel()
                isLoading = false
                notice = selectedEngine == .sharedDeepL ? AppNotice(kind: .info, message: "请在设置的“账号与安全”中注册或登录，领取公共体验额度。") : .translation(.missingDeepLKey)
                return
            }
            translationTask = Task { [weak self] in
                await self?.translateWithDeepL(
                    prepared.0,
                    originalText: cleanText,
                    source: effectiveSource,
                    target: target,
                    glossaryMap: prepared.1,
                    requestID: requestID
                )
            }
        }
    }

    @available(macOS 15.0, *)
    func completeAppleTranslation(using session: TranslationSession, request: AppleTranslationRequest) async {
        guard appleTranslationRequest?.id == request.id,
              translationRequestGate.accepts(request.id) else { return }
        do {
            try await AppleLanguagePreparation.prepare(session, source: request.source, target: request.target) { status in
                if self.appleTranslationRequest?.id == request.id {
                    self.translationProgress = status
                    self.armAppleWatchdog(id: request.id, seconds: 300, stage: "准备语言包")
                }
            }
            guard appleTranslationRequest?.id == request.id else { return }
            armAppleWatchdog(id: request.id, seconds: 90, stage: "翻译文字")
            let response = try await session.translate(request.text)
            guard appleTranslationRequest?.id == request.id,
                  translationRequestGate.accepts(request.id) else { return }
            acceptTranslation(
                response.targetText,
                original: request.originalText,
                source: request.source,
                target: request.target,
                glossaryMap: request.glossaryMap
            )
            translationRequestGate.cancel()
            translationTask = nil
            appleTranslationRequest = nil
            isLoading = false
        } catch {
            guard appleTranslationRequest?.id == request.id,
                  translationRequestGate.accepts(request.id) else { return }
            translationRequestGate.cancel()
            translationTask = nil
            appleTranslationRequest = nil
            isLoading = false
            notice = .translation(.explain(error, engine: .apple))
        }
    }

    private func beginImageTranslation(source: String, target: String) {
        guard let sourceImage, !recognizedImageBlocks.isEmpty, !isLoading else { return }
        cancelSpeechPreload()
        stopOnlineSpeech()
        isLoading = true
        translationProgress = "正在检查翻译服务…"
        let imageRequestID = imageRequestGate.begin()
        notice = nil
        translatedText = ""
        translatedImage = nil
        appleTranslationRequest = nil

        switch selectedEngine {
        case .apple:
            if #available(macOS 15.0, *) {
                let request = AppleImageTranslationRequest(
                    blocks: recognizedImageBlocks,
                    source: source,
                    target: target
                )
                appleImageTranslationRequest = request
            } else {
                isLoading = false
                notice = .translation(.appleSystemRequired)
            }
        case .deepl, .sharedDeepL:
            guard selectedEngine == .sharedDeepL ? SharedTrialAccount.shared.isSignedIn : hasDeepLKey else {
                isLoading = false
                notice = selectedEngine == .sharedDeepL ? AppNotice(kind: .info, message: "请在设置的“账号与安全”中注册或登录，领取公共体验额度。") : .translation(.missingDeepLKey)
                return
            }
            let blocks = recognizedImageBlocks
            imageTranslationTask?.cancel()
            imageTranslationTask = Task { [weak self] in
                guard let self else { return }
                await self.translateImageWithDeepL(sourceImage: sourceImage, blocks: blocks, source: source, target: target, requestID: imageRequestID)
            }
        }
    }

    @available(macOS 15.0, *)
    func completeAppleImageTranslation(using session: TranslationSession, request: AppleImageTranslationRequest) async {
        guard appleImageTranslationRequest?.id == request.id, let sourceImage else { return }
        do {
            try await AppleLanguagePreparation.prepare(session, source: request.source, target: request.target) { status in
                if self.appleImageTranslationRequest?.id == request.id {
                    self.translationProgress = status
                    self.armAppleWatchdog(id: request.id, seconds: 300, stage: "准备语言包")
                }
            }
            guard appleImageTranslationRequest?.id == request.id else { return }
            var translations: [String] = []
            translations.reserveCapacity(request.blocks.count)
            for (index, block) in request.blocks.enumerated() {
                translationProgress = "正在翻译图片：\(index + 1) / \(request.blocks.count) 处"
                let prepared = glossaryPreparedText(block.text, source: request.source, target: request.target)
                armAppleWatchdog(id: request.id, seconds: 90, stage: "翻译图片文字")
                let response = try await session.translate(prepared.0)
                guard appleImageTranslationRequest?.id == request.id else { return }
                translations.append(restoreGlossary(in: response.targetText, replacements: prepared.1))
            }
            finishImageTranslation(
                sourceImage: sourceImage,
                blocks: request.blocks,
                translations: translations,
                source: request.source,
                target: request.target
            )
            appleImageTranslationRequest = nil
            imageTranslationTask = nil
        } catch {
            guard appleImageTranslationRequest?.id == request.id else { return }
            appleImageTranslationRequest = nil
            imageTranslationTask = nil
            isLoading = false
            notice = .translation(.explain(error, engine: .apple))
        }
    }

    private func translateImageWithDeepL(
        sourceImage: NSImage,
        blocks: [RecognizedImageBlock],
        source: String,
        target: String,
        requestID: UUID
    ) async {
        do {
            var maps: [[String: String]] = []
            let preparedTexts = blocks.map { block -> String in
                let prepared = glossaryPreparedText(block.text, source: source, target: target)
                maps.append(prepared.1)
                return prepared.0
            }
            let rawTranslations = try await deepLTranslations(for: preparedTexts, source: source, target: target)
            guard !Task.isCancelled, imageRequestGate.accepts(requestID) else { return }
            let translations = zip(rawTranslations, maps).map { restoreGlossary(in: $0.0, replacements: $0.1) }
            finishImageTranslation(
                sourceImage: sourceImage,
                blocks: blocks,
                translations: translations,
                source: source,
                target: target
            )
            Task { await self.refreshSelectedEngineUsage() }
        } catch {
            guard !Task.isCancelled, imageRequestGate.accepts(requestID) else { return }
            isLoading = false
            showTranslationError(error)
        }
    }

    private func deepLTranslations(for texts: [String], source: String, target: String) async throws -> [String] {
        if selectedEngine == .sharedDeepL {
            return try await SharedTrialAccount.shared.translate(texts, source: source, target: target)
        }
        return try await DeepLClient(apiKey: deepLAPIKey).translate(texts, source: source, target: target)
    }

    private func finishImageTranslation(
        sourceImage: NSImage,
        blocks: [RecognizedImageBlock],
        translations: [String],
        source: String,
        target: String
    ) {
        guard translations.count == blocks.count else {
            isLoading = false
            setError("图片译文数量与识别结果不一致，请重新尝试")
            return
        }
        imageBlockTranslations = translations
        imageTranslationTask = nil
        editableImageBlocks = zip(blocks, translations).map { block, translation in
            EditableImageTranslationBlock(
                id: block.id,
                originalText: block.text,
                translatedText: translation,
                boundingBox: block.boundingBox
            )
        }
        translatedImage = renderedTranslationImage(
            source: sourceImage,
            edits: editableImageBlocks,
            style: imageRenderStyle
        )
        translatedText = translations.joined(separator: "\n")
        saveHistory(original: blocks.map(\.text).joined(separator: "\n"), result: translatedText, source: source, target: target)
        saveImageHistory(sourceImage: sourceImage, source: source, target: target)
        isLoading = false
    }

    func setImageRenderStyle(_ style: ImageTranslationRenderStyle) {
        guard imageRenderStyle != style else { return }
        imageRenderStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: imageRenderStyleKey)
        guard let sourceImage,
              !editableImageBlocks.isEmpty else { return }
        translatedImage = renderedTranslationImage(
            source: sourceImage,
            edits: editableImageBlocks,
            style: style
        )
        updateCurrentImageHistory()
    }

    func applyImageEdits(_ edits: [EditableImageTranslationBlock]) {
        guard let sourceImage else { return }
        editableImageBlocks = edits
        translatedText = edits.map(\.translatedText).joined(separator: "\n")
        translatedImage = renderedTranslationImage(
            source: sourceImage,
            edits: edits,
            style: imageRenderStyle
        )
        updateCurrentImageHistory()
        setSuccess("译文框修改已应用")
    }

    func resetImageEdits() -> [EditableImageTranslationBlock] {
        zip(recognizedImageBlocks, imageBlockTranslations).map { block, translation in
            EditableImageTranslationBlock(
                id: block.id,
                originalText: block.text,
                translatedText: translation,
                boundingBox: block.boundingBox
            )
        }
    }

    func copyTranslatedImage() {
        guard let translatedImage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([translatedImage])
        imageActionLabel = "已复制 ✓"
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            imageActionLabel = "复制图片"
        }
    }

    func saveTranslatedImage() {
        guard let translatedImage,
              let tiffData = translatedImage.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiffData),
              let pngData = representation.representation(using: .png, properties: [:]) else {
            setError("无法生成可保存的译文图片")
            return
        }
        let panel = NSSavePanel()
        panel.title = "保存译文图片"
        panel.nameFieldStringValue = "译文图片.png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try pngData.write(to: destination, options: .atomic)
            imageActionLabel = "保存成功 ✓"
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                imageActionLabel = "复制图片"
            }
        } catch {
            setError("保存译文图片失败：\(error.localizedDescription)")
        }
    }

    private func translateWithDeepL(
        _ cleanText: String,
        originalText: String,
        source: String,
        target: String,
        glossaryMap: [String: String],
        requestID: UUID
    ) async {
        do {
            let values = try await deepLTranslations(for: [cleanText], source: source, target: target)
            guard !Task.isCancelled, translationRequestGate.accepts(requestID), let result = values.first else { return }
            acceptTranslation(
                result,
                original: originalText,
                source: source,
                target: target,
                glossaryMap: glossaryMap
            )
            finishTextTranslation(requestID: requestID)
            Task { await self.refreshSelectedEngineUsage() }
        } catch {
            guard !Task.isCancelled, translationRequestGate.accepts(requestID) else { return }
            finishTextTranslation(requestID: requestID)
            showTranslationError(error)
        }
    }

    private func finishTextTranslation(requestID: UUID) {
        guard translationRequestGate.accepts(requestID) else { return }
        translationRequestGate.cancel()
        translationTask = nil
        isLoading = false
    }

    private func refreshSelectedEngineUsage() async {
        if selectedEngine == .sharedDeepL {
            await SharedTrialAccount.shared.refresh()
        } else {
            await fetchDeepLUsage()
        }
    }

    func fetchDeepLUsage() async {
        guard hasDeepLKey, !deepLAPIKey.isEmpty else {
            deepLUsage = nil
            return
        }
        guard let url = URL(string: "https://api-free.deepl.com/v2/usage") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("DeepL-Auth-Key \(deepLAPIKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let usage = try JSONDecoder().decode(DeepLUsagePayload.self, from: data)
            deepLUsage = usage
        } catch {
            // 用量获取失败不影响翻译主流程
        }
    }

    private func showTranslationError(_ error: Error) {
        notice = error is TrialServiceError ? AppNotice(kind: .error, message: error.localizedDescription) : .translation(.explain(error, engine: .deepl))
    }

    private func acceptTranslation(
        _ result: String,
        original: String,
        source: String,
        target: String,
        glossaryMap: [String: String]
    ) {
        let finalResult = restoreGlossary(in: result, replacements: glossaryMap)
        translatedText = finalResult
        saveHistory(original: original, result: finalResult, source: source, target: target)
        preGenerateResultSpeech(text: finalResult, language: target)
    }

    func copyResult() {
        guard !translatedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translatedText, forType: .string)
        copyLabel = "已复制 ✓"
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            copyLabel = "复制译文"
        }
    }

    func copyPopupResult() {
        guard !popupTranslatedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(popupTranslatedText, forType: .string)
        copyLabel = "已复制 ✓"
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            copyLabel = "复制译文"
        }
    }

    func replaceSelectedText(in processID: pid_t) {
        guard !popupTranslatedText.isEmpty,
              let application = NSRunningApplication(processIdentifier: processID) else { return }
        let pasteboard = NSPasteboard.general
        let snapshot = pasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(popupTranslatedText, forType: .string)
        application.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return }
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
                self?.restorePasteboard(snapshot, to: pasteboard)
            }
        }
    }

    func speakSource() {
        guard !sourceText.isEmpty else { return }
        let language = sourceLanguage == "auto" ? detectSupportedLanguage(in: sourceText) : sourceLanguage
        startOnlineSpeech(sourceText, language: language)
    }

    func speakResult() {
        guard !translatedText.isEmpty else { return }
        if let player = resultAudioPlayer, player.isPlaying {
            player.pause()
            isSpeakingResult = true
            isResultSpeechPaused = true
        } else if let player = resultAudioPlayer, isResultSpeechPaused {
            player.play()
            isSpeakingResult = true
            isResultSpeechPaused = false
        } else if isPreparingSpeech {
            stopOnlineSpeech()
        } else {
            startOnlineSpeech(translatedText, language: targetLanguage)
        }
    }

    func setOnlineVoicePersona(_ persona: OnlineVoicePersona) {
        guard onlineVoicePersona != persona else { return }
        stopOnlineSpeech()
        cancelSpeechPreload()
        onlineVoicePersona = persona
        UserDefaults.standard.set(persona.rawValue, forKey: voicePersonaKey)
        preGenerateResultSpeech()
    }

    func setOnlineSpeechRatePercent(_ value: Int) {
        let clamped = min(30, max(-30, value))
        guard onlineSpeechRatePercent != clamped else { return }
        stopOnlineSpeech()
        cancelSpeechPreload()
        onlineSpeechRatePercent = clamped
        UserDefaults.standard.set(clamped, forKey: speechRateKey)
        preGenerateResultSpeech()
    }

    var speechRateDisplayText: String {
        onlineSpeechRatePercent > 0 ? "+\(onlineSpeechRatePercent)%" : "\(onlineSpeechRatePercent)%"
    }

    var speechCacheSizeText: String {
        ByteCountFormatter.string(fromByteCount: speechCacheBytes, countStyle: .file)
    }

    var accessibilityPermissionText: String {
        AXIsProcessTrusted() ? "已允许" : "未允许"
    }

    var speechRecognitionPermissionText: String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return "已允许"
        case .denied, .restricted: return "未允许"
        case .notDetermined: return "尚未请求"
        @unknown default: return "未知"
        }
    }

    var microphonePermissionText: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "已允许"
        case .denied, .restricted: return "未允许"
        case .notDetermined: return "尚未请求"
        @unknown default: return "未知"
        }
    }

    func clearSpeechCache() {
        cancelSpeechPreload()
        stopOnlineSpeech()
        let directory = onlineSpeechCacheDirectory
        if let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
        refreshSpeechCacheSize()
        speechStatusMessage = "语音缓存已清理"
    }

    func refreshSpeechCacheSize() {
        let keys: Set<URLResourceKey> = [.fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: onlineSpeechCacheDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        speechCacheBytes = files.reduce(0) { partial, file in
            partial + Int64((try? file.resourceValues(forKeys: keys).fileSize) ?? 0)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.isSpeakingResult = false
            self?.isResultSpeechPaused = false
            self?.speechStatusMessage = nil
            self?.speechHighlightedSentenceIndex = -1
            self?.speechHighlightTask?.cancel()
            self?.speechHighlightTask = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isSpeakingResult = false
            self?.isResultSpeechPaused = false
            self?.speechHighlightedSentenceIndex = -1
            self?.speechStatusMessage = nil
        }
    }

    var highlightedTranslatedText: AttributedString {
        var value = AttributedString(translatedText)
        guard speechHighlightedSentenceIndex >= 0,
              speechHighlightedSentenceIndex < speechSentences.count else { return value }
        let sentence = speechSentences[speechHighlightedSentenceIndex]
        guard let range = translatedText.range(of: sentence),
              let lower = AttributedString.Index(range.lowerBound, within: value),
              let upper = AttributedString.Index(range.upperBound, within: value) else { return value }
        value[lower..<upper].backgroundColor = .blue.opacity(0.18)
        value[lower..<upper].foregroundColor = .blue
        return value
    }

    private func startOnlineSpeech(_ text: String, language: String) {
        stopOnlineSpeech()
        guard let voice = OnlineTTSService.voice(for: language, persona: onlineVoicePersona) else {
            speechStatusMessage = "在线朗读仅支持中文、英文、日文和韩文"
            return
        }
        let cacheDirectory = onlineSpeechCacheDirectory
        let rate = onlineSpeechRate
        let cacheKey = OnlineTTSService.cacheKey(text: text, language: language, voice: voice, rate: rate)
        let audioURL = cacheDirectory.appendingPathComponent("\(cacheKey).mp3")
        speechAudioURL = audioURL

        if FileManager.default.fileExists(atPath: audioURL.path) {
            playOnlineAudio(at: audioURL)
            return
        }

        isPreparingSpeech = true
        let matchingPreload = speechPreloadKey == cacheKey ? speechPreloadTask : nil
        speechStatusMessage = matchingPreload == nil ? "正在联网生成自然语音…" : "语音即将就绪…"
        speechTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resultURL: URL
                if let matchingPreload, let preloadedURL = await matchingPreload.value {
                    resultURL = preloadedURL
                } else {
                    resultURL = try await self.onlineSpeechService.synthesize(
                        text: text,
                        voice: voice,
                        outputURL: audioURL,
                        rate: rate
                    )
                }
                guard !Task.isCancelled, self.speechAudioURL == audioURL else { return }
                self.isPreparingSpeech = false
                self.playOnlineAudio(at: resultURL)
                self.trimOnlineSpeechCache()
            } catch is CancellationError {
                self.isPreparingSpeech = false
            } catch {
                guard self.speechAudioURL == audioURL else { return }
                self.isPreparingSpeech = false
                self.startSystemSpeechFallback(text: text, language: language)
            }
        }
    }

    private func preGenerateResultSpeech(text: String? = nil, language: String? = nil) {
        let value = (text ?? translatedText).trimmingCharacters(in: .whitespacesAndNewlines)
        let language = language ?? targetLanguage
        guard !value.isEmpty,
              let voice = OnlineTTSService.voice(for: language, persona: onlineVoicePersona) else { return }

        let cacheKey = OnlineTTSService.cacheKey(
            text: value,
            language: language,
            voice: voice,
            rate: onlineSpeechRate
        )
        let audioURL = onlineSpeechCacheDirectory.appendingPathComponent("\(cacheKey).mp3")
        guard !FileManager.default.fileExists(atPath: audioURL.path) else { return }

        cancelSpeechPreload()
        speechPreloadKey = cacheKey
        speechPreloadTask = Task { [weak self] in
            guard let self else { return nil }
            do {
                let resultURL = try await self.onlineSpeechService.synthesize(
                    text: value,
                    voice: voice,
                    outputURL: audioURL,
                    rate: self.onlineSpeechRate
                )
                guard !Task.isCancelled else { return nil }
                self.trimOnlineSpeechCache()
                if self.speechPreloadKey == cacheKey {
                    self.speechPreloadKey = nil
                    self.speechPreloadTask = nil
                }
                return resultURL
            } catch {
                if self.speechPreloadKey == cacheKey {
                    self.speechPreloadKey = nil
                    self.speechPreloadTask = nil
                }
                return nil
            }
        }
    }

    private func cancelSpeechPreload() {
        speechPreloadTask?.cancel()
        speechPreloadTask = nil
        speechPreloadKey = nil
    }

    private var onlineSpeechCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(SecureKeyStore.applicationID == "com.yijian.translator.kimi"
                                   ? "com.yijian.translator/OnlineSpeech"
                                   : SecureKeyStore.applicationID + "/OnlineSpeech", isDirectory: true)
    }

    private func trimOnlineSpeechCache(maximumBytes: Int = 40 * 1024 * 1024) {
        let directory = onlineSpeechCacheDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            var entries = files.compactMap { url -> (URL, Int, Date)? in
                guard let values = try? url.resourceValues(forKeys: keys),
                      let size = values.fileSize else { return nil }
                return (url, size, values.contentModificationDate ?? .distantPast)
            }
            var total = entries.reduce(0) { $0 + $1.1 }
            entries.sort { $0.2 < $1.2 }
            for entry in entries where total > maximumBytes {
                try? FileManager.default.removeItem(at: entry.0)
                total -= entry.1
            }
            speechCacheBytes = Int64(total)
        } catch {
            // Cache maintenance must never interrupt translation or speech.
        }
    }

    private func playOnlineAudio(at url: URL) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            resultAudioPlayer = player
            speechStatusMessage = nil
            isSpeakingResult = true
            isResultSpeechPaused = false
            speechSentences = sentenceParts(in: translatedText)
            startSpeechHighlighting(player: player)
            player.play()
        } catch {
            isSpeakingResult = false
            speechStatusMessage = "无法播放在线音频：\(error.localizedDescription)"
        }
    }

    private func stopOnlineSpeech() {
        resultAudioPlayer?.stop()
        resultAudioPlayer = nil
        fallbackSpeechSynthesizer.stopSpeaking(at: .immediate)
        speechTask?.cancel()
        speechTask = nil
        speechHighlightTask?.cancel()
        speechHighlightTask = nil
        speechHighlightedSentenceIndex = -1
        isPreparingSpeech = false
        isSpeakingResult = false
        isResultSpeechPaused = false
        speechStatusMessage = nil
        speechAudioURL = nil
    }

    private func sentenceParts(in text: String) -> [String] {
        var values: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { values.append(sentence) }
        }
        return values.isEmpty && !text.isEmpty ? [text] : values
    }

    private func startSpeechHighlighting(player: AVAudioPlayer) {
        speechHighlightTask?.cancel()
        guard !speechSentences.isEmpty else { return }
        speechHighlightTask = Task { @MainActor [weak self, weak player] in
            while !Task.isCancelled, let self, let player, player.duration > 0 {
                let progress = min(0.999, max(0, player.currentTime / player.duration))
                self.speechHighlightedSentenceIndex = min(
                    self.speechSentences.count - 1,
                    Int(progress * Double(self.speechSentences.count))
                )
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func startSystemSpeechFallback(text: String, language: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: speechLocales[language] ?? "en-US")
        utterance.rate = max(0.35, min(0.60, 0.48 + Float(onlineSpeechRatePercent) / 200))
        speechStatusMessage = "在线语音暂不可用，已使用系统备用语音"
        isSpeakingResult = true
        isResultSpeechPaused = false
        fallbackSpeechSynthesizer.speak(utterance)
    }

    @Published private(set) var popupVoiceActive = false
    @Published private(set) var popupSilenceCountdown: Int?
    private let popupVoiceInput = PopupVoiceInput()

    func startPopupVoiceInput() {
        if isListening || isVoiceProcessing { cancelVoiceInput() }
        popupTranslationTask?.cancel()
        popupAppleTranslationRequest = nil
        popupIsLoading = false
        popupSourceText = ""
        popupTranslatedText = ""
        popupSourceLanguage = "zh-CN"
        popupTargetLanguage = "en"
        popupNotice = nil
        popupVoiceActive = true
        selectionPanelController.show(model: self, anchor: NSEvent.mouseLocation, sourceProcessID: nil)
        popupVoiceInput.start(onText: { [weak self] text in
            self?.popupSourceText = String(text.prefix(maxSourceCharacters))
        }, onCountdown: { [weak self] seconds in
            self?.popupSilenceCountdown = seconds
        }, onFinish: { [weak self] error in
            guard let self else { return }
            self.popupVoiceActive = false
            self.popupSilenceCountdown = nil
            if let error {
                self.popupNotice = AppNotice(kind: .error, message: error)
            } else if !self.popupSourceText.isEmpty {
                self.translatePopup()
            } else {
                self.popupNotice = AppNotice(kind: .info, message: "没有听到语音，请从菜单栏重新开始")
            }
        })
    }

    func finishPopupVoiceInput() { popupVoiceInput.finish() }

    func cancelPopupVoiceInput() {
        popupVoiceInput.cancel()
        popupVoiceActive = false
        popupSilenceCountdown = nil
        popupSourceText = ""
    }

    func toggleListening() {
        cancelPopupVoiceInput()
        if isListening || isVoiceProcessing { stopListening(); return }
        if sourceLanguage == "auto" && !LocalSpeechRecognizer.isModelInstalled {
            showVoiceModelDownload = true
            return
        }
        beginVoiceAuthorization()
    }

    func downloadVoiceModelAndStart() {
        showVoiceModelDownload = false
        cancelVoiceInput()
        let id = UUID()
        voiceSession = id
        isVoiceProcessing = true
        notice = nil
        voiceInputStatus = "正在下载语音模型（约 148MB）…"
        voiceOperation = Task { [weak self] in
            guard let self else { return }
            do {
                try await LocalSpeechRecognizer.downloadModel { [weak self] status in
                    guard let self, self.voiceSession == id, self.isVoiceProcessing else { return }
                    self.voiceInputStatus = status
                }
                guard self.voiceSession == id, !Task.isCancelled else { return }
                self.isVoiceProcessing = false
                self.voiceSession = nil
                self.beginVoiceAuthorization()
            } catch {
                guard self.voiceSession == id, !Task.isCancelled else { return }
                self.cancelVoiceInput()
                self.notice = AppNotice(kind: .error, message: error.localizedDescription, retryVoiceModelDownload: true)
            }
        }
    }

    private func beginVoiceAuthorization() {
        cancelVoiceInput()
        cancelTranslation()
        cancelSpeechPreload()
        stopOnlineSpeech()
        let id = UUID()
        voiceSession = id
        let language = sourceLanguage
        isVoiceProcessing = true
        voiceInputStatus = "正在准备麦克风…"
        voiceOperation = Task { [weak self] in
            guard let self else { return }
            // Automatic mode is local; it does not send speech to Apple's online recognizer.
            if language != "auto" {
                let status = await self.requestSpeechAuthorization()
                guard self.voiceSession == id, !Task.isCancelled else { return }
                guard status == .authorized else {
                    self.cancelVoiceInput()
                    self.setError("请在系统设置中允许“Yike”使用语音识别", action: .openSpeechRecognitionSettings)
                    return
                }
            }
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard self.voiceSession == id, !Task.isCancelled else { return }
            guard allowed else {
                self.cancelVoiceInput()
                self.setError("请在系统设置中允许“Yike”使用麦克风", action: .openMicrophoneSettings)
                return
            }
            self.speechBaseText = self.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            self.lastRecognizedText = self.speechBaseText
            self.detectedVoiceLanguage = nil
            self.isVoiceProcessing = false
            if language == "auto" { self.startLocalRecording(id: id) }
            else { self.startSystemListening(language: language, id: id) }
        }
    }

    private func startLocalRecording(id: UUID) {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("YikeVoice", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent(UUID().uuidString + ".wav")
            voiceAudioURL = file
            let recorder = try AVAudioRecorder(url: file, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
            ])
            recorder.isMeteringEnabled = true
            voiceRecorder = recorder
            guard recorder.record(forDuration: 60) else { throw LocalSpeechError.recognitionFailed }
            isListening = true
            notice = nil
            voiceInputStatus = "自动识别语言 · 回车完成"
            voiceMeterTask = Task { [weak self] in
                guard let self else { return }
                var lastSound = Date()
                var heardSpeech = false
                let started = Date()
                var lastPreview = Date()
                var noiseFloor = -55.0
                var speechStarted: Date?
                while !Task.isCancelled, self.voiceSession == id, self.isListening {
                    recorder.updateMeters()
                    let db = recorder.averagePower(forChannel: 0)
                    self.microphoneLevel = VoiceMeter.normalized(decibels: db)
                    let elapsed = Date().timeIntervalSince(started)
                    if !heardSpeech && elapsed < 1.0 { noiseFloor = max(noiseFloor, Double(db)) }
                    let speechThreshold = max(-38.0, noiseFloor + 10.0)
                    if Double(db) >= speechThreshold {
                        speechStarted = speechStarted ?? Date()
                        if Date().timeIntervalSince(speechStarted!) >= 0.18 {
                            heardSpeech = true
                            lastSound = Date()
                        }
                    } else {
                        speechStarted = nil
                    }
                    let remaining = heardSpeech
                        ? max(1, 3 - Int(Date().timeIntervalSince(lastSound))) : nil
                    if self.voiceSilenceCountdown != remaining {
                        self.voiceSilenceCountdown = remaining
                    }
                    if heardSpeech && Date().timeIntervalSince(lastPreview) >= 2 && self.partialVoiceTask == nil {
                        lastPreview = Date()
                        self.updateLocalPreview(id: id, file: file)
                    }
                    if !recorder.isRecording || (heardSpeech && Date().timeIntervalSince(lastSound) >= 3) || (!heardSpeech && Date().timeIntervalSince(started) >= 3) {
                        if heardSpeech {
                            self.autoSubmitAfterVoice = true
                            self.finishLocalRecording(id: id)
                        }
                        else { self.cancelVoiceInput(); self.setInfo("没有听到清晰语音，请检查麦克风后再试。") }
                        return
                    }
                    do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
                }
            }
        } catch {
            cancelVoiceInput()
            setError("无法启动录音：\(error.localizedDescription) 请检查麦克风连接及权限。")
        }
    }

    private func updateLocalPreview(id: UUID, file: URL) {
        partialVoiceTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".wav")
            defer {
                try? FileManager.default.removeItem(at: snapshot)
                if self.voiceSession == id { self.partialVoiceTask = nil }
            }
            do {
                let data = try LiveWaveSnapshot.data(from: Data(contentsOf: file))
                try data.write(to: snapshot, options: .atomic)
                let result = try await self.partialSpeech.transcribe(audioURL: snapshot)
                guard self.voiceSession == id, self.isListening, !Task.isCancelled else { return }
                self.appendVoiceText(result.text, language: result.language)
                self.detectedVoiceLanguage = result.language
                self.voiceInputStatus = "\(languageName(result.language)) · 正在聆听 · 回车完成"
            } catch {
                // Short/incomplete speech can be undecidable; keep listening. The
                // final pass supplies either the full transcript or a useful error.
            }
        }
    }

    func handleReturnKey() {
        if isListening { stopListening() }
        else if !isVoiceProcessing { translate() }
    }

    func stopListening() {
        if isVoiceProcessing { cancelVoiceInput(); return }
        guard isListening else { return }
        if voiceRecorder != nil, let id = voiceSession { finishLocalRecording(id: id) }
        else { cancelVoiceInput() }
    }

    func cancelVoiceSubmission() {
        if sourceText == lastRecognizedText { sourceText = speechBaseText }
        cancelVoiceInput()
    }

    private func finishLocalRecording(id: UUID) {
        guard voiceSession == id, let recorder = voiceRecorder, let file = voiceAudioURL else { return }
        partialVoiceTask?.cancel()
        partialVoiceTask = nil
        partialSpeech.cancel()
        let duration = recorder.currentTime
        recorder.stop()
        voiceRecorder = nil
        voiceMeterTask?.cancel()
        voiceMeterTask = nil
        isListening = false
        voiceSilenceCountdown = nil
        microphoneLevel = 0
        guard duration > 0.4 else { cancelVoiceInput(); setInfo("录音太短，请说一句完整的话后再试。"); return }
        isVoiceProcessing = true
        voiceInputStatus = "正在本机识别语言和文字…"
        voiceOperation = Task { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                let result = try await self.localSpeech.transcribe(audioURL: file)
                guard self.voiceSession == id, !Task.isCancelled else { return }
                self.appendVoiceText(result.text, language: result.language)
                self.detectedVoiceLanguage = result.language
                self.targetLanguage = result.language == "en" ? "zh-CN" : (result.language == "zh-CN" ? "en" : "zh-CN")
                self.isVoiceProcessing = false
                self.voiceSession = nil
                self.voiceAudioURL = nil
                self.voiceInputStatus = "已识别：\(languageName(result.language))"
                if self.autoSubmitAfterVoice {
                    self.autoSubmitAfterVoice = false
                    self.translate()
                }
            } catch {
                guard self.voiceSession == id, !Task.isCancelled else { return }
                self.cancelVoiceInput()
                self.setError(error.localizedDescription)
            }
        }
    }

    private func appendVoiceText(_ rawText: String, language: String) {
        let spokenText = language == "zh-CN"
            ? (rawText.applyingTransform(StringTransform(rawValue: "Traditional-Simplified"), reverse: false) ?? rawText)
            : rawText
        let combined = speechBaseText.isEmpty ? spokenText : "\(speechBaseText) \(spokenText)"
        lastRecognizedText = String(combined.prefix(maxSourceCharacters))
        sourceText = lastRecognizedText
    }

    func cancelVoiceInput() {
        voiceSession = nil
        partialVoiceTask?.cancel()
        partialVoiceTask = nil
        partialSpeech.cancel()
        voiceOperation?.cancel()
        voiceOperation = nil
        voiceMeterTask?.cancel()
        voiceMeterTask = nil
        voiceRecorder?.stop()
        voiceRecorder = nil
        localSpeech.cancel()
        if let file = voiceAudioURL { try? FileManager.default.removeItem(at: file) }
        voiceAudioURL = nil
        silenceTask?.cancel()
        silenceTask = nil
        voiceSilenceCountdown = nil
        autoSubmitAfterVoice = false
        audioEngine.stop()
        if hasInputTap { audioEngine.inputNode.removeTap(onBus: 0); hasInputTap = false }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isListening = false
        isVoiceProcessing = false
        microphoneLevel = 0
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private func startSystemListening(language: String, id: UUID) {
        guard let locale = speechLocales[language], let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            cancelVoiceInput()
            setError("当前语言的系统语音识别暂不可用，请检查网络后重试，或改用自动检测。")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            cancelVoiceInput(); setError("没有可用的麦克风，请检查设备连接。"); return
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            let db = 20 * log10(max(0.000001, sqrt(sum / Float(buffer.frameLength))))
            let level = VoiceMeter.normalized(decibels: db)
            Task { @MainActor in
                guard let self, self.voiceSession == id else { return }
                self.microphoneLevel = level
                if db > -42 { self.scheduleAutomaticStop(after: 3, id: id) }
            }
        }
        hasInputTap = true
        do {
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            notice = nil
            voiceInputStatus = "正在聆听\(languageName(language))…"
            scheduleAutomaticStop(after: 3, id: id)
        } catch {
            cancelVoiceInput(); setError("无法启动麦克风，请检查设备后重试。"); return
        }
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.voiceSession == id else { return }
                if let result {
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { self.appendVoiceText(text, language: language) }
                    if result.isFinal { self.cancelVoiceInput(); return }
                }
                if error != nil {
                    self.cancelVoiceInput()
                    self.setError("系统语音识别中断，已保留识别文字。请检查网络，或改用自动检测进行本地识别。")
                }
            }
        }
    }

    private func scheduleAutomaticStop(after seconds: Double, id: UUID) {
        silenceTask?.cancel()
        voiceSilenceCountdown = Int(seconds)
        silenceTask = Task { @MainActor [weak self] in
            for remaining in stride(from: Int(seconds), through: 1, by: -1) {
                guard let self, self.voiceSession == id, self.isListening else { return }
                self.voiceSilenceCountdown = remaining
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            guard let self, self.voiceSession == id, self.isListening else { return }
            self.voiceSilenceCountdown = nil
            self.stopListening()
            if !self.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.translate()
            }
        }
    }

    private var imageHistoryDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(SecureKeyStore.applicationID == "com.yijian.translator.kimi"
                                   ? "Mac翻译" : SecureKeyStore.applicationID, isDirectory: true)
            .appendingPathComponent("ImageHistory", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return base
    }

    private func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff) else { return nil }
        return representation.representation(using: .png, properties: [:])
    }

    private func saveImageHistory(sourceImage: NSImage, source: String, target: String) {
        guard imageHistoryRecordingEnabled,
              let translatedImage,
              let sourceData = pngData(for: sourceImage),
              let translatedData = pngData(for: translatedImage) else {
            currentImageHistoryID = nil
            return
        }
        let id = UUID()
        let sourceFileName = "\(id.uuidString)-source.png"
        let translatedFileName = "\(id.uuidString)-translated.png"
        let sourceURL = imageHistoryDirectory.appendingPathComponent(sourceFileName)
        let translatedURL = imageHistoryDirectory.appendingPathComponent(translatedFileName)
        do {
            try sourceData.write(to: sourceURL, options: .atomic)
            try translatedData.write(to: translatedURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: translatedURL)
            currentImageHistoryID = nil
            return
        }

        imageHistory.insert(ImageTranslationHistory(
            id: id,
            date: Date(),
            source: source,
            target: target,
            engine: selectedEngine.shortName,
            style: imageRenderStyle,
            sourceFileName: sourceFileName,
            translatedFileName: translatedFileName,
            originalText: sourceText,
            translatedText: translatedText,
            blocks: editableImageBlocks
        ), at: 0)
        if imageHistory.count > 10 {
            for item in imageHistory.dropFirst(10) {
                removeImageHistoryFiles(item)
            }
            imageHistory = Array(imageHistory.prefix(10))
        }
        currentImageHistoryID = id
        persistImageHistory()
    }

    private func updateCurrentImageHistory() {
        guard let currentImageHistoryID,
              let translatedImage,
              let translatedData = pngData(for: translatedImage),
              let index = imageHistory.firstIndex(where: { $0.id == currentImageHistoryID }) else { return }
        let destination = imageHistoryDirectory.appendingPathComponent(imageHistory[index].translatedFileName)
        guard (try? translatedData.write(to: destination, options: .atomic)) != nil else { return }
        imageHistory[index].date = Date()
        imageHistory[index].style = imageRenderStyle
        imageHistory[index].translatedText = translatedText
        imageHistory[index].blocks = editableImageBlocks
        persistImageHistory()
    }

    func imageHistoryImage(_ item: ImageTranslationHistory, translated: Bool) -> NSImage? {
        let name = translated ? item.translatedFileName : item.sourceFileName
        return NSImage(contentsOf: imageHistoryDirectory.appendingPathComponent(name))
    }

    func use(_ item: ImageTranslationHistory) {
        cancelTranslation()
        guard let source = imageHistoryImage(item, translated: false),
              let translated = imageHistoryImage(item, translated: true) else {
            setError("这条图片历史的文件已不存在")
            return
        }
        cancelSpeechPreload()
        sourceImage = source
        translatedImage = translated
        sourceLanguage = item.source
        targetLanguage = item.target
        imageRenderStyle = item.style
        sourceText = item.originalText
        translatedText = item.translatedText
        editableImageBlocks = item.blocks
        recognizedImageBlocks = item.blocks.map {
            RecognizedImageBlock(id: $0.id, text: $0.originalText, boundingBox: $0.boundingBox)
        }
        imageBlockTranslations = item.blocks.map(\.translatedText)
        currentImageHistoryID = item.id
        notice = nil
    }

    func deleteImageHistory(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let removed = imageHistory.filter { ids.contains($0.id) }
        removed.forEach(removeImageHistoryFiles)
        imageHistory.removeAll { ids.contains($0.id) }
        if let currentImageHistoryID, ids.contains(currentImageHistoryID) {
            self.currentImageHistoryID = nil
        }
        persistImageHistory()
    }

    func clearImageHistory() {
        imageHistory.forEach(removeImageHistoryFiles)
        imageHistory = []
        currentImageHistoryID = nil
        UserDefaults.standard.removeObject(forKey: imageHistoryKey)
    }

    private func removeImageHistoryFiles(_ item: ImageTranslationHistory) {
        try? FileManager.default.removeItem(at: imageHistoryDirectory.appendingPathComponent(item.sourceFileName))
        try? FileManager.default.removeItem(at: imageHistoryDirectory.appendingPathComponent(item.translatedFileName))
    }

    func setImageHistoryRecording(_ enabled: Bool) {
        imageHistoryRecordingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: imageHistoryEnabledKey)
    }

    private func persistImageHistory() {
        if let data = try? JSONEncoder().encode(imageHistory) {
            UserDefaults.standard.set(data, forKey: imageHistoryKey)
        }
    }

    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    func deleteHistory(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        history.removeAll { ids.contains($0.id) }
        persistHistory()
    }

    func copyHistoryOriginal(_ item: TranslationHistory) {
        copyTextToPasteboard(item.original)
    }

    func copyHistoryResult(_ item: TranslationHistory) {
        copyTextToPasteboard(item.result)
    }

    private func copyTextToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveHistory(original: String, result: String, source: String, target: String) {
        guard historyRecordingEnabled else { return }
        let item = TranslationHistory(
            id: UUID(), original: original, result: result,
            source: source, target: target,
            date: Date(), engine: selectedEngine.shortName
        )
        let pinned = history.filter { $0.isPinned && $0.original != original }
        let unpinned = history.filter { !$0.isPinned && $0.original != original }
        let unpinnedKeep = Array(([item] + unpinned).prefix(30))
        history = pinned + unpinnedKeep
        persistHistory()
    }

    func togglePin(_ item: TranslationHistory) {
        guard let index = history.firstIndex(where: { $0.id == item.id }) else { return }
        history[index].isPinned.toggle()
        let pinned = history.filter { $0.isPinned }
        let unpinned = history.filter { !$0.isPinned }
        history = pinned + unpinned
        persistHistory()
    }

    func setHistoryRecording(_ enabled: Bool) {
        historyRecordingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: historyEnabledKey)
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    private func decodeEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

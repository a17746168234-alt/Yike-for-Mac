import AppKit
import Foundation

private struct VoiceTestFailure: Error { let message: String }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw VoiceTestFailure(message: message) }
}

@main
struct VoiceEditingTests {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        for (language, expected, text) in [("zh", "zh-CN", "你好"), ("en", "en", "Hello"), ("ja", "ja", "こんにちは"), ("ko", "ko", "안녕하세요"), ("de", "de", "Guten Tag"), ("fr", "fr", "Bonjour")] {
            let data = try JSONSerialization.data(withJSONObject: ["result": ["language": language], "transcription": [["text": text]]])
            try require(tryParse(data) == LocalSpeechResult(text: text, language: expected), "detected audio language mapping")
        }
        for data in [Data(#"{"result":{"language":"en"},"transcription":[{"text":"  "}]}"#.utf8),
                     Data(#"{"result":{"language":"es"},"transcription":[{"text":"Hola"}]}"#.utf8)] {
            try require(tryParse(data) == nil, "empty or unsupported result must not masquerade as English")
        }
        try require(VoiceMeter.normalized(decibels: -80) == 0, "silence should be flat")
        try require(VoiceMeter.normalized(decibels: -25) > VoiceMeter.normalized(decibels: -45), "louder audio should produce taller waveform")
        try require(VoiceMeter.normalized(decibels: .infinity) == 0 && VoiceMeter.normalized(decibels: 10) == 1, "meter bounds")

        let model = TranslatorViewModel()
        model.historyRecordingEnabled = false
        model.sourceText = "原文保留"
        model.translatedText = "Original translation"
        model.editTranslatedText("Edited translation\nSecond line")
        try require(model.translatedText == "Edited translation\nSecond line" && model.sourceText == "原文保留", "editing must preserve source and multiline result")
        model.editTranslatedText("")
        try require(model.translatedText.isEmpty && model.sourceText == "原文保留", "deleting result must not clear source")
        try require(model.saveDeepLKey("voice-test-key"), "test key save")
        try require(model.deepLKeyFeedback?.kind == .success && model.deepLKeyFeedback?.message.contains("保存成功") == true, "save feedback must survive engine switch")
        try require(model.saveDeepLKey("updated-test-key"), "test key update")
        try require(model.deepLKeyFeedback?.message.contains("保存成功") == true, "update feedback missing")
        try require(model.saveDeepLKey(""), "test key removal")
        try require(!model.hasDeepLKey && model.deepLKeyFeedback?.message.contains("移除") == true, "removal must not claim saved")
        model.cancelVoiceInput()
        try require(!model.isListening && !model.isVoiceProcessing && model.microphoneLevel == 0, "voice cancellation resets state")
        model.isListening = true
        model.handleReturnKey()
        try require(!model.isListening && !model.isLoading && model.sourceText == "原文保留", "Return ends recording without translating or clearing source")
        model.downloadVoiceModelAndStart()
        model.handleReturnKey()
        try require(model.isVoiceProcessing && !model.isLoading, "Return during recognition must not cancel or translate")
        model.cancelVoiceInput()
        let timeout = LocalSpeechRecognizer.downloadFailureReason(URLError(.timedOut))
        let offline = LocalSpeechRecognizer.downloadFailureReason(URLError(.notConnectedToInternet))
        try require(timeout.contains("超时") && timeout.contains("-1001"), "timeout should include reason and code")
        try require(offline.contains("代理") && offline.contains("-1009"), "offline error should explain proxy possibility")
        var edited = ""
        let resultEditor = ResultTextEditor(text: .init(get: { edited }, set: { edited = $0 }), isVoiceActive: true, onVoiceReturn: { model.handleReturnKey() })
        model.isListening = true
        let handled = resultEditor.makeCoordinator().textView(NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        try require(handled && !model.isListening && !model.isLoading, "Return in result editor should also finish voice input")
        print("VoiceEditingTests: language mapping, empty/unsupported results, real amplitude mapping, editable result, isolated key save/update/remove feedback, voice cancellation passed")
    }

    static func tryParse(_ data: Data) -> LocalSpeechResult? { try? LocalSpeechResult.parse(data) }
}

import Foundation

@main
struct LocalSpeechIntegrationTests {
    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let recognizer = LocalSpeechRecognizer(modelURL: root.appendingPathComponent("ggml-base.bin"),
            engineURL: root.appendingPathComponent("whisper-build/bin/whisper-cli"))
        for (audio, expected) in [("en", "en"), ("zh", "zh-CN"), ("ja", "ja"), ("ko", "ko")] {
            let file = root.appendingPathComponent("fixtures/\(audio).wav")
            let result = try await recognizer.transcribe(audioURL: file)
            precondition(result.language == expected && !result.text.isEmpty)
            precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("fixtures/\(audio).result.json").path))
            print("PASS full local process: \(audio) -> \(result.language), output cleaned")
        }
        let cancelled = Task { try await recognizer.transcribe(audioURL: root.appendingPathComponent("fixtures/en.wav")) }
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("cancelled result must not be accepted") }
        catch is CancellationError { print("PASS in-flight local process cancellation") }
    }
}

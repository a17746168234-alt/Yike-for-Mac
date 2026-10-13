import Foundation

@main struct LiveSpeechTests {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let recognizer = LocalSpeechRecognizer(modelURL: root.appendingPathComponent("ggml-base.bin"), engineURL: root.appendingPathComponent("whisper-build/bin/whisper-cli"))
        for (language, expected) in [("en","en"),("zh","zh-CN"),("ja","ja"),("ko","ko")] {
            let fixture = try Data(contentsOf: root.appendingPathComponent("fixtures/\(language).wav"))
            // At 16kHz/16-bit mono, this represents the first four seconds while
            // the file is still being written and its RIFF size is not finalized.
            var live = Data(fixture.prefix(min(fixture.count, 128044)))
            for i in 4..<8 { live[i] = 0 }
            let snapshot = try LiveWaveSnapshot.data(from: live)
            let file = output.appendingPathComponent("partial-\(language).wav")
            try snapshot.write(to: file)
            let result = try await recognizer.transcribe(audioURL: file)
            precondition(result.language == expected && !result.text.isEmpty, "Partial language mismatch: \(language) -> \(result.language)")
            print("PASS during-recording preview: \(language), \(result.text.count) characters")
            try FileManager.default.removeItem(at: file)
        }
        do { _ = try LiveWaveSnapshot.data(from: Data(repeating: 0, count: 44)); preconditionFailure("invalid WAV accepted") }
        catch { print("PASS malformed/short audio rejected") }
        let cancelled = Task { try await recognizer.transcribe(audioURL: root.appendingPathComponent("fixtures/en.wav")) }
        try await Task.sleep(for: .milliseconds(10)); cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("cancelled preview accepted") }
        catch is CancellationError { print("PASS cancellation rejects late preview") }
    }
}

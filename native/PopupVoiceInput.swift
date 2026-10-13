import Foundation
import Speech
import AVFoundation

@MainActor
final class PopupVoiceInput {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var timeout: Task<Void, Never>?
    private var session: UUID?
    private var hasTap = false
    private var completion: ((String?) -> Void)?
    private var countdown: ((Int?) -> Void)?
    private let silenceTimeout: UInt64 = 3
    private let silenceThreshold: Float = 0.015

    func start(onText: @escaping (String) -> Void, onCountdown: @escaping (Int?) -> Void, onFinish: @escaping (String?) -> Void) {
        cancel()
        let id = UUID()
        session = id
        completion = onFinish
        countdown = onCountdown
        Task {
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard session == id else { return }
            guard status == .authorized else {
                finish(error: "请在系统设置 → 隐私与安全性 → 语音识别中允许 Yike")
                return
            }
            let permitted = await AVCaptureDevice.requestAccess(for: .audio)
            guard session == id else { return }
            guard permitted else {
                finish(error: "请在系统设置 → 隐私与安全性 → 麦克风中允许 Yike")
                return
            }
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable else {
                finish(error: "中文语音识别暂不可用，请稍后重试")
                return
            }
            let audioRequest = SFSpeechAudioBufferRecognitionRequest()
            audioRequest.shouldReportPartialResults = true
            request = audioRequest
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                finish(error: "没有可用的麦克风")
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                audioRequest.append(buffer)
                let rms = Self.rms(of: buffer)
                Task { @MainActor in
                    self.handleAudioLevel(rms, id: id)
                }
            }
            hasTap = true
            do {
                engine.prepare()
                try engine.start()
            } catch {
                finish(error: "无法启动麦克风，请稍后重试")
                return
            }
            // Finish after three seconds without meaningful microphone input.
            scheduleStop(after: silenceTimeout, id: id)
            recognition = recognizer.recognitionTask(with: audioRequest) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.session == id else { return }
                    if let result {
                        let rawText = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                        let text = Self.simplifiedChinese(rawText)
                        onText(text)
                        if result.isFinal { self.finish(); return }
                    }
                    if error != nil { self.finish(error: "语音识别中断，请重新尝试") }
                }
            }
        }
    }

    private func handleAudioLevel(_ rms: Float, id: UUID) {
        guard session == id else { return }
        if rms >= silenceThreshold {
            scheduleStop(after: silenceTimeout, id: id)
        }
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?.pointee else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        var energy: Float = 0
        for index in 0..<frameCount {
            let sample = channelData[index]
            energy += sample * sample
        }
        return (energy / Float(frameCount)).squareRoot()
    }

    private static func simplifiedChinese(_ text: String) -> String {
        text.applyingTransform(StringTransform(rawValue: "Traditional-Simplified"), reverse: false) ?? text
    }

    private func scheduleStop(after seconds: UInt64, id: UUID) {
        timeout?.cancel()
        countdown?(Int(seconds))
        timeout = Task {
            for remaining in stride(from: Int(seconds), through: 1, by: -1) {
                guard session == id else { return }
                countdown?(remaining)
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            guard session == id else { return }
            finish()
        }
    }

    func finish(error: String? = nil) {
        guard session != nil else { return }
        let callback = completion
        cancel()
        callback?(error)
    }

    func cancel() {
        session = nil
        timeout?.cancel()
        timeout = nil
        countdown?(nil)
        countdown = nil
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        request?.endAudio()
        recognition?.cancel()
        request = nil
        recognition = nil
        completion = nil
    }
}

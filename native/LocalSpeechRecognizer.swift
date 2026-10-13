import Foundation
import AVFoundation
import CryptoKit

enum LocalSpeechError: LocalizedError {
    case missingEngine, downloadFailed, invalidModel, noSpeech, unsupportedLanguage(String), recognitionFailed
    case downloadHTTP(Int), downloadSourcesFailed(String)
    var errorDescription: String? {
        switch self {
        case .missingEngine: return "此安装包缺少本地语音引擎，请安装完整的最新版 Yike，或手动选择语音语言。"
        case .downloadFailed: return "语音模型下载失败，请检查网络后重试；也可手动选择语言，使用系统语音识别。"
        case .downloadHTTP(let status): return "下载服务器返回 HTTP \(status)"
        case .downloadSourcesFailed(let details): return "语音模型下载未完成。\(details)\n请检查网络及代理是否正常，再点击“重新下载”；也可以在左上角手动选择语言，使用系统语音识别。"
        case .invalidModel: return "语音模型文件不完整或校验失败，请重新下载。"
        case .noSpeech: return "没有识别到清晰的语音。请靠近麦克风，说一句完整的话后再试。"
        case .unsupportedLanguage(let code): return "识别到的语言（\(code)）不在中英日韩德法范围内；请说完整句子重试，或手动选择语言。"
        case .recognitionFailed: return "本地语音识别未能完成，请缩短录音后重试，或手动选择语言。"
        }
    }
}

/// Uses the delegate download API so byte progress is delivered on macOS too.
final class SpeechModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var lastReported: Int64 = 0

    init(report: @escaping @Sendable (Int64) -> Void) { self.report = report }

    func download(from url: URL, configuration: URLSessionConfiguration) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: url)
                self.task = task
                lock.unlock()
                task.resume()
            }
        }, onCancel: { self.cancel() })
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    private func finish(_ result: Result<(URL, URLResponse), Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        if let continuation { continuation.resume(with: result) }
        else if case .success(let (url, _)) = result { try? FileManager.default.removeItem(at: url) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response else { throw LocalSpeechError.downloadFailed }
            let saved = FileManager.default.temporaryDirectory.appendingPathComponent("YikeModel-\(UUID().uuidString).tmp")
            try FileManager.default.moveItem(at: location, to: saved)
            finish(.success((saved, response)))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten - lastReported >= 1_000_000 || totalBytesWritten == totalBytesExpectedToWrite {
            lastReported = totalBytesWritten
            report(totalBytesWritten)
        }
    }
}

struct LocalSpeechResult: Equatable {
    let text: String
    let language: String

    static func parse(_ data: Data) throws -> Self {
        struct Output: Decodable {
            struct Result: Decodable { let language: String }
            struct Segment: Decodable { let text: String }
            let result: Result
            let transcription: [Segment]
        }
        let output = try JSONDecoder().decode(Output.self, from: data)
        let languages = ["zh": "zh-CN", "en": "en", "ja": "ja", "ko": "ko", "de": "de", "fr": "fr"]
        guard let language = languages[output.result.language] else {
            throw LocalSpeechError.unsupportedLanguage(output.result.language)
        }
        let text = output.transcription.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalSpeechError.noSpeech }
        return Self(text: text, language: language)
    }
}

@MainActor
final class LocalSpeechRecognizer {
    static let modelBytes = 147_951_465
    static let modelSHA256 = "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
    static var modelURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.yijian.translator.kimi")
            .appendingPathComponent("SpeechModels/ggml-base.bin")
    }
    static var isModelInstalled: Bool {
        (try? modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) == modelBytes
    }
    static func validateModel(at url: URL) throws {
        guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == modelBytes else { throw LocalSpeechError.invalidModel }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == modelSHA256 else { throw LocalSpeechError.invalidModel }
    }
    static func downloadFailureReason(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut: return "连接或传输超时（\(nsError.code)）"
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "下载连接不可用或中断，可能与网络或代理有关（\(nsError.code)）"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
                return "无法连接下载服务器，请检查网络或代理（\(nsError.code)）"
            default: return "\(nsError.localizedDescription)（\(nsError.code)）"
            }
        }
        return error.localizedDescription
    }

    static func downloadModel(onProgress: @escaping @MainActor (String) -> Void = { _ in }) async throws {
        let sources = [("官方源", "huggingface.co"), ("备用源", "hf-mirror.com")]
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 1800
        var failures: [String] = []
        for (name, host) in sources {
            try Task.checkCancellation()
            onProgress("正在连接\(name)…")
            let source = URL(string: "https://\(host)/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!
            let downloader = SpeechModelDownload { bytes in
                Task { @MainActor in onProgress("\(name) · \(min(148, bytes / 1_000_000)) / 148 MB") }
            }
            do {
                let (temporary, response) = try await downloader.download(from: source, configuration: config)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse else { throw LocalSpeechError.downloadFailed }
                guard response.statusCode == 200 else { throw LocalSpeechError.downloadHTTP(response.statusCode) }
                onProgress("正在校验语音模型…")
                try validateModel(at: temporary)
                try Task.checkCancellation()
                let destination = modelURL
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else { try FileManager.default.moveItem(at: temporary, to: destination) }
                return
            } catch {
                try Task.checkCancellation()
                failures.append("\(name)：\(downloadFailureReason(error))")
            }
        }
        throw LocalSpeechError.downloadSourcesFailed(failures.joined(separator: "；"))
    }

    private var validatedModification: Date?
    private var process: Process?
    private var deadline: Task<Void, Never>?
    private let selectedModelURL: URL
    private let selectedEngineURL: URL?

    init(modelURL: URL? = nil, engineURL: URL? = nil) {
        selectedModelURL = modelURL ?? Self.modelURL
        selectedEngineURL = engineURL ?? Bundle.main.url(forAuxiliaryExecutable: "whisper-cli")
    }

    func cancel() {
        deadline?.cancel()
        deadline = nil
        if let process, process.isRunning { process.terminate() }
    }

    func transcribe(audioURL: URL) async throws -> LocalSpeechResult {
        try Task.checkCancellation()
        let attributes = try selectedModelURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        if validatedModification == nil || validatedModification != attributes.contentModificationDate || attributes.fileSize != Self.modelBytes {
            try Self.validateModel(at: selectedModelURL)
            validatedModification = attributes.contentModificationDate
        }
        guard let engine = selectedEngineURL else { throw LocalSpeechError.missingEngine }
        let prefix = audioURL.deletingPathExtension().appendingPathExtension("result")
        let json = prefix.appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: json) }
        let runner = Process()
        runner.executableURL = engine
        runner.arguments = ["-m", selectedModelURL.path, "-f", audioURL.path, "-l", "auto", "-oj", "-of", prefix.path,
                            "-t", "4", "-nt", "-np"]
        runner.standardOutput = FileHandle.nullDevice
        runner.standardError = FileHandle.nullDevice
        process = runner
        defer { deadline?.cancel(); deadline = nil; process = nil }
        let code: Int32 = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                runner.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
                do {
                    try runner.run()
                    deadline = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(120)) } catch { return }
                        self?.cancel()
                    }
                } catch { runner.terminationHandler = nil; continuation.resume(throwing: error) }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel() } })
        try Task.checkCancellation()
        guard code == 0, let data = try? Data(contentsOf: json) else { throw LocalSpeechError.recognitionFailed }
        return try LocalSpeechResult.parse(data)
    }
}

enum VoiceMeter {
    static func normalized(decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
        return min(1, max(0, (decibels + 55) / 45))
    }
}

/// AVAudioRecorder updates WAV lengths when recording stops. Repair a private
/// snapshot so Whisper can read all PCM captured so far without stopping the mic.
enum LiveWaveSnapshot {
    static func data(from recording: Data) throws -> Data {
        guard recording.count >= 44, String(data: recording[0..<4], encoding: .ascii) == "RIFF",
              String(data: recording[8..<12], encoding: .ascii) == "WAVE" else { throw LocalSpeechError.noSpeech }
        var data = recording
        func size(at offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | (Int(data[offset + $1]) << (8 * $1)) }
        }
        func put(_ value: Int, at offset: Int) {
            for i in 0..<4 { data[offset+i] = UInt8((value >> (8*i)) & 255) }
        }
        var offset = 12
        while offset + 8 <= data.count {
            if String(data: data[offset..<offset+4], encoding: .ascii) == "data" {
                let count = (data.count - offset - 8) / 2 * 2
                guard count >= 16000 else { throw LocalSpeechError.noSpeech }
                data = data.prefix(offset + 8 + count)
                put(count, at: offset+4); put(data.count-8, at: 4)
                return data
            }
            let length = size(at: offset+4)
            guard length <= data.count-offset-8 else { throw LocalSpeechError.noSpeech }
            offset += 8 + length + (length % 2)
        }
        throw LocalSpeechError.noSpeech
    }
}

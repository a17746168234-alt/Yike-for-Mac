import Foundation

private final class DownloadProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    func record(_ value: Int64) { lock.lock(); bytes = max(bytes, value); lock.unlock() }
    var total: Int64 { lock.lock(); defer { lock.unlock() }; return bytes }
}

@main struct SpeechDownloadTests {
    static func main() async {
        do {
            let base = URL(string: CommandLine.arguments[1])!
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5
            let progress = DownloadProgressCounter()
            let downloader = SpeechModelDownload { progress.record($0) }
            let (file, response) = try await downloader.download(from: base.appendingPathComponent("model"), configuration: config)
            defer { try? FileManager.default.removeItem(at: file) }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  (try Data(contentsOf: file)).count == 2_097_152,
                  progress.total == 2_097_152 else { throw LocalSpeechError.downloadFailed }
            for cancelImmediately in [false, true] {
                let pending = Task { try await SpeechModelDownload { _ in }.download(from: base.appendingPathComponent("slow"), configuration: config) }
                if !cancelImmediately { try await Task.sleep(for: .milliseconds(120)) }
                pending.cancel()
                do {
                    let (unexpected, _) = try await pending.value
                    try? FileManager.default.removeItem(at: unexpected)
                    throw LocalSpeechError.recognitionFailed
                } catch is CancellationError {
                } catch let error as URLError where error.code == .cancelled {
                }
            }
            print("SpeechDownloadTests: downloaded bytes, real byte progress, in-flight cancellation and pre-start cancellation passed")
        } catch {
            FileHandle.standardError.write(Data("SpeechDownloadTests FAILED: \(error)\n".utf8))
            exit(1)
        }
    }
}

import CryptoKit
import Foundation

// Based on SwiftEdgeTTS (MIT License).
// Copyright (c) 2024 SwiftEdgeTTS Contributors.

enum OnlineTTSError: LocalizedError {
    case invalidRequest
    case noAudio
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "朗读内容或语言无效"
        case .noAudio:
            return "在线语音服务没有返回音频"
        case .network:
            return "无法连接在线语音服务"
        }
    }
}

enum OnlineVoicePersona: String, CaseIterable, Identifiable {
    case female
    case male

    var id: String { rawValue }

    var title: String {
        switch self {
        case .female: return "女声"
        case .male: return "男声"
        }
    }

    var icon: String {
        self == .female ? "person.crop.circle" : "person.crop.circle.fill"
    }
}

final class OnlineTTSService {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
    }

    static func voice(for language: String, persona: OnlineVoicePersona) -> String? {
        let voices: [String: [OnlineVoicePersona: String]] = [
            "en": [
                .female: "en-US-JennyNeural",
                .male: "en-US-AndrewMultilingualNeural"
            ],
            "zh-CN": [
                .female: "zh-CN-XiaoxiaoNeural",
                .male: "zh-CN-YunxiNeural"
            ],
            "ja": [
                .female: "ja-JP-NanamiNeural",
                .male: "ja-JP-KeitaNeural"
            ],
            "de": [
                .female: "de-DE-KatjaNeural",
                .male: "de-DE-ConradNeural"
            ],
            "fr": [
                .female: "fr-FR-DeniseNeural",
                .male: "fr-FR-HenriNeural"
            ],
            "ko": [
                .female: "ko-KR-SunHiNeural",
                .male: "ko-KR-InJoonNeural"
            ]
        ]
        return voices[language]?[persona]
    }

    static func cacheKey(text: String, language: String, voice: String, rate: String) -> String {
        let value = "\(language)|\(voice)|\(rate)|\(text)"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func synthesize(text: String, voice: String, outputURL: URL, rate: String = "-6%") async throws -> URL {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !voice.isEmpty else {
            throw OnlineTTSError.invalidRequest
        }

        let audio = try await synthesizeViaWebSocket(text: text, voice: voice, rate: rate)
        guard !audio.isEmpty else { throw OnlineTTSError.noAudio }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try audio.write(to: outputURL, options: .atomic)
        return outputURL
    }

    private let synthesizeBaseURL = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
    private let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private let secMsGecVersion = "1-143.0.3650.75"
    private let windowsEpochOffset: TimeInterval = 11_644_473_600

    private lazy var timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter
    }()

    private func synthesizeViaWebSocket(text: String, voice: String, rate: String) async throws -> Data {
        let connectionID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var components = URLComponents(string: synthesizeBaseURL)!
        components.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: trustedClientToken),
            URLQueryItem(name: "Sec-MS-GEC", value: generateSecMsGecToken()),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: secMsGecVersion),
            URLQueryItem(name: "ConnectionId", value: connectionID)
        ]
        guard let url = components.url else { throw OnlineTTSError.invalidRequest }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("gzip, deflate, br, zstd", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue("muid=\(UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased());", forHTTPHeaderField: "Cookie")

        let socket = session.webSocketTask(with: request)
        socket.resume()
        do {
            try await sendSpeechConfig(on: socket)
            try await sendSSML(createSSML(text: text, voice: voice, rate: rate), on: socket)
            var audio = Data()

            receiveLoop: while !Task.isCancelled {
                switch try await socket.receive() {
                case .string(let message):
                    if parseHeaders(from: message)["Path"] == "turn.end" {
                        break receiveLoop
                    }
                case .data(let data):
                    if let chunk = extractAudioChunk(from: data) {
                        audio.append(chunk)
                    }
                @unknown default:
                    break receiveLoop
                }
            }
            socket.cancel(with: .normalClosure, reason: nil)
            if Task.isCancelled { throw CancellationError() }
            return audio
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            if error is CancellationError { throw error }
            throw OnlineTTSError.network(error)
        }
    }

    private func generateSecMsGecToken() -> String {
        var ticks = Date().timeIntervalSince1970 + windowsEpochOffset
        ticks -= fmod(ticks, 300)
        ticks *= 10_000_000
        let payload = String(format: "%.0f%@", ticks, trustedClientToken)
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    private func sendSpeechConfig(on socket: URLSessionWebSocketTask) async throws {
        let payload = "{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":" +
            "{\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"}," +
            "\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}\r\n"
        let message = "X-Timestamp:\(timestampFormatter.string(from: Date()))\r\n" +
            "Content-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n\(payload)"
        try await socket.send(.string(message))
    }

    private func sendSSML(_ ssml: String, on socket: URLSessionWebSocketTask) async throws {
        let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let message = "X-RequestId:\(requestID)\r\nContent-Type:application/ssml+xml\r\n" +
            "X-Timestamp:\(timestampFormatter.string(from: Date()))Z\r\nPath:ssml\r\n\r\n\(ssml)"
        try await socket.send(.string(message))
    }

    private func createSSML(text: String, voice: String, rate: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
        let parts = voice.split(separator: "-")
        let locale = parts.count >= 2 ? "\(parts[0])-\(parts[1])" : "en-US"
        return "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' " +
            "xmlns:mstts='http://www.w3.org/2001/mstts' xml:lang='\(locale)'><voice name='\(voice)'>" +
            "<prosody rate='\(rate)' pitch='+0Hz' volume='+0%'>\(escaped)</prosody></voice></speak>"
    }

    private func parseHeaders(from value: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in value.components(separatedBy: "\r\n") {
            guard let separator = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<separator])] = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
        }
        return headers
    }

    private func extractAudioChunk(from data: Data) -> Data? {
        guard data.count >= 2 else { return nil }
        let headerLength = Int(data[0]) << 8 | Int(data[1])
        guard data.count >= headerLength + 2 else { return nil }
        let headerStart = data.index(data.startIndex, offsetBy: 2)
        let headerEnd = data.index(headerStart, offsetBy: headerLength)
        guard let header = String(data: data[headerStart..<headerEnd], encoding: .utf8),
              parseHeaders(from: header)["Path"] == "audio" else { return nil }
        let bodyStart = data.count >= headerEnd + 2 && data[headerEnd] == 13 && data[headerEnd + 1] == 10
            ? headerEnd + 2 : headerEnd
        guard bodyStart < data.endIndex else { return nil }
        return Data(data[bodyStart...])
    }
}

import CryptoKit
import Foundation

// Based on SwiftEdgeTTS (MIT License).
// Copyright (c) 2024 SwiftEdgeTTS Contributors.

enum OnlineTTSError: LocalizedError {
    case invalidRequest
    case noAudio
    case httpStatus(Int)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "朗读内容或语言无效"
        case .noAudio:
            return "在线语音服务没有返回音频"
        case .httpStatus(let status):
            return "在线语音服务拒绝请求（HTTP \(status)）"
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
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try audio.write(to: outputURL, options: .atomic)
        return outputURL
    }

    private static let synthesizeBaseURL = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
    private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let secMsGecVersion = "2-143.0.3650.75"
    private static let windowsEpochOffset: TimeInterval = 11_644_473_600

    private struct HandshakeFailure: Error {
        let response: HTTPURLResponse
    }

    private lazy var timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter
    }()

    private func synthesizeViaWebSocket(text: String, voice: String, rate: String) async throws -> Data {
        do {
            return try await synthesizeViaWebSocket(text: text, voice: voice, rate: rate, at: Date())
        } catch let failure as HandshakeFailure {
            // Match edge-tts's one bounded 403 retry using the service clock. A wrong
            // system clock can otherwise produce a token from the wrong five-minute window.
            guard failure.response.statusCode == 403,
                  let serverDate = Self.serverDate(from: failure.response) else {
                throw OnlineTTSError.httpStatus(failure.response.statusCode)
            }
            try Task.checkCancellation()
            do {
                return try await synthesizeViaWebSocket(text: text, voice: voice, rate: rate, at: serverDate)
            } catch let retryFailure as HandshakeFailure {
                throw OnlineTTSError.httpStatus(retryFailure.response.statusCode)
            }
        }
    }

    static func makeWebSocketRequest(at date: Date, connectionID: String) throws -> URLRequest {
        var components = URLComponents(string: synthesizeBaseURL)!
        components.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: trustedClientToken),
            URLQueryItem(name: "Sec-MS-GEC", value: generateSecMsGecToken(at: date)),
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
        return request
    }

    private func synthesizeViaWebSocket(text: String, voice: String, rate: String, at date: Date) async throws -> Data {
        try Task.checkCancellation()
        let connectionID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let request = try Self.makeWebSocketRequest(at: date, connectionID: connectionID)
        let socket = session.webSocketTask(with: request)
        socket.resume()
        return try await withTaskCancellationHandler {
            do {
                try await sendSpeechConfig(on: socket)
                try await sendSSML(createSSML(text: text, voice: voice, rate: rate), on: socket)
                var audio = Data()

                receiveLoop: while !Task.isCancelled {
                    switch try await socket.receive() {
                    case .string(let message):
                        if Self.parseHeaders(from: message)["Path"] == "turn.end" {
                            break receiveLoop
                        }
                    case .data(let data):
                        if let chunk = Self.extractAudioChunk(from: data) {
                            audio.append(chunk)
                        }
                    @unknown default:
                        break receiveLoop
                    }
                }
                socket.cancel(with: .normalClosure, reason: nil)
                try Task.checkCancellation()
                return audio
            } catch {
                socket.cancel(with: .goingAway, reason: nil)
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                if let response = socket.response as? HTTPURLResponse, response.statusCode >= 400 {
                    throw HandshakeFailure(response: response)
                }
                throw OnlineTTSError.network(error)
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    static func generateSecMsGecToken(at date: Date) -> String {
        var ticks = date.timeIntervalSince1970 + windowsEpochOffset
        ticks -= fmod(ticks, 300)
        ticks *= 10_000_000
        let payload = "Copyright (C) Microsoft Corporation. All rights reserved." +
            String(format: "%.0f%@", ticks, trustedClientToken)
        let data = Data(payload.utf8)
        let digest = Data(SHA256.hash(data: data))
        let dataWords = littleEndianWords(data)
        let keys = littleEndianWords(digest)
        let swapped = cs64WordSwap(dataWords, keys: keys)
        let reversible = cs64Reversible(dataWords, keys: keys)
        let cs64Words = [swapped.0 ^ reversible.0, swapped.1 ^ reversible.1]
        let cs64 = cs64Words.flatMap { word in
            (0..<4).map { shift in UInt8(truncatingIfNeeded: word >> (shift * 8)) }
        }.map { String(format: "%02X", $0) }.joined()
        let sha256 = digest.map { String(format: "%02X", $0) }.joined()
        return "\(cs64)-\(sha256)"
    }

    // Sec-MS-GEC v2, introduced by the service in October 2026.
    // Port of edge-tts PR #492 (LGPLv3), https://github.com/rany2/edge-tts/pull/492.
    // All arithmetic intentionally wraps at UInt32.
    private static func littleEndianWords(_ data: Data) -> [UInt32] {
        let bytes = Array(data)
        var result: [UInt32] = []
        for index in stride(from: 0, to: bytes.count, by: 4) {
            var word: UInt32 = 0
            for offset in 0..<4 where index + offset < bytes.count {
                word |= UInt32(bytes[index + offset]) << (offset * 8)
            }
            result.append(word)
        }
        if result.count % 2 != 0 { result.append(0) }
        return result
    }

    private static func rotate16(_ value: UInt32) -> UInt32 {
        (value << 16) | (value >> 16)
    }

    private static func cs64WordSwap(_ words: [UInt32], keys: [UInt32]) -> (UInt32, UInt32) {
        let a = keys[0] | 1
        let b = keys[1] | 1
        var accumulator: UInt32 = 0
        var last: UInt32 = 0
        for index in stride(from: 0, to: words.count, by: 2) {
            let x = words[index]
            let y = words[index + 1]
            var value = rotate16(x) &* 0xEF0569FB &+ x &* a
            value = rotate16(value)
            var q = value &* 0x76F50F34
            q = rotate16(q) &* 0xC3EFEA97 &+ q
            accumulator = accumulator &+ q
            value = rotate16(y) &* 0xC31713DB &+ y &* b
            value = rotate16(value)
            q = value &* 0x1881CE3C
            last = rotate16(q) &* 0x35BD1EC9 &+ q
            accumulator = accumulator &+ last
        }
        return (last, accumulator)
    }

    private static func cs64Reversible(_ words: [UInt32], keys: [UInt32]) -> (UInt32, UInt32) {
        let a = keys[0] | 1
        let b = keys[1] | 1
        var state: UInt32 = 0
        var accumulator: UInt32 = 0
        for index in stride(from: 0, to: words.count, by: 2) {
            state = (state &+ words[index]) &* a
            for constant: UInt32 in [0xCF98B111, 0x87085B9F, 0x12CEB96D, 0x257E1D83] {
                state = rotate16(state) &* constant
            }
            var value = (words[index + 1] &+ state) &* b
            value = rotate16(value) &* 0xA27416F5
            value = rotate16(value) &* 0xD38396FF
            value = rotate16(value)
            accumulator = accumulator &+ state
            state = rotate16(value &* 0x7C932B89) &* 0xBFA49F69
            accumulator = accumulator &+ state
        }
        return (state, accumulator)
    }

    private static func serverDate(from response: HTTPURLResponse) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "Date") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
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

    private static func parseHeaders(from value: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in value.components(separatedBy: "\r\n") {
            guard let separator = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<separator])] = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
        }
        return headers
    }

    static func extractAudioChunk(from data: Data) -> Data? {
        guard data.count >= 2 else { return nil }
        let secondByte = data.index(after: data.startIndex)
        let headerLength = Int(data[data.startIndex]) << 8 | Int(data[secondByte])
        guard data.count >= headerLength + 2 else { return nil }
        let headerStart = data.index(data.startIndex, offsetBy: 2)
        let headerEnd = data.index(headerStart, offsetBy: headerLength)
        guard let header = String(data: data[headerStart..<headerEnd], encoding: .utf8),
              parseHeaders(from: header)["Path"] == "audio" else { return nil }
        guard headerEnd < data.endIndex else { return nil }
        return Data(data[headerEnd...])
    }
}

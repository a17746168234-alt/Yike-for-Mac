import Foundation

private struct ProtocolTestFailure: Error {
    let message: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ProtocolTestFailure(message: message) }
}

@main
struct OnlineTTSProtocolTests {
    static func main() async throws {
        try testAuthentication()
        try testRequest()
        try testAudioFrames()
        try await testCancellation()
        print("OnlineTTSProtocolTests passed: captured GEC v2 vector, 5-minute rollover, authentication request, exact audio payload, malformed frames and cancellation without output")
    }

    static func testAuthentication() throws {
        // The middle fixture is from the successful Edge v2 packet capture in
        // edge-tts PR #492. Adjacent windows were checked with its Python CS64
        // implementation. These constants exercise uint32 overflow and byte order.
        let previous = "DAAEAD2FD5438630-897933E9C951AADAA0A792FFD23FBB12339BBBBA71EA7BF84FFA0C777C3C9550"
        let captured = "492D7694A183A45E-56E821F95D4579C5B7C7E33DC7303FF379EC36D510213555BBBB9EB17EF15876"
        let next = "6D26B5F5B70269AD-280E82E1BBE24E4E8866E3502EB6277B9436F61ABDC1C224518A038BBD7BBDAD"
        for (timestamp, expected) in [
            (1791887999.999, previous),
            (1791888000.0, captured),
            (1791888299.999, captured),
            (1791888300.0, next)
        ] {
            let actual = OnlineTTSService.generateSecMsGecToken(at: Date(timeIntervalSince1970: timestamp))
            try require(actual == expected, "GEC v2 differs from known fixture at \(timestamp): \(actual)")
        }
    }

    static func testRequest() throws {
        let connectionID = "000102030405060708090A0B0C0D0E0F"
        let date = Date(timeIntervalSince1970: 1791888000)
        let request = try OnlineTTSService.makeWebSocketRequest(at: date, connectionID: connectionID)
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ProtocolTestFailure(message: "invalid WebSocket URL")
        }
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        try require(components.scheme == "wss" && components.host == "speech.platform.bing.com", "wrong online speech endpoint")
        try require(components.path == "/consumer/speech/synthesize/readaloud/edge/v1", "wrong speech endpoint path")
        try require(items["TrustedClientToken"] == "6A5AA1D4EAFF4E9FB37E23D68491D6F4", "missing trusted client token")
        try require(items["Sec-MS-GEC-Version"] == "2-143.0.3650.75", "GEC version must match v2 authentication")
        try require(items["Sec-MS-GEC"] == "492D7694A183A45E-56E821F95D4579C5B7C7E33DC7303FF379EC36D510213555BBBB9EB17EF15876", "request must use v2 token")
        try require(items["ConnectionId"] == connectionID, "connection identifier changed")
        let userAgent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
        try require(userAgent.contains("Chrome/143.0.0.0") && userAgent.contains("Edg/143.0.0.0"), "browser and GEC versions diverged")
        try require(request.value(forHTTPHeaderField: "Origin") == "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", "missing read-aloud origin")
        try require(request.value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9", "missing supported request locale")
        try require(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache", "authentication request must not be cached")
        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        try require(cookie.range(of: "^muid=[0-9A-F]{32};$", options: .regularExpression) != nil, "invalid request cookie")
    }

    static func frame(header: String, payload: Data) -> Data {
        let headerData = Data(header.utf8)
        precondition(headerData.count < 65536)
        var value = Data([UInt8(headerData.count >> 8), UInt8(headerData.count & 255)])
        value.append(headerData)
        value.append(payload)
        return value
    }

    static func testAudioFrames() throws {
        let header = "X-RequestId:fixture\r\nContent-Type:audio/mpeg\r\nPath:audio\r\n"
        let mp3 = Data([0xFF, 0xFB, 0x90, 0x64, 0x00, 0x2A])
        try require(OnlineTTSService.extractAudioChunk(from: frame(header: header, payload: mp3)) == mp3, "audio payload was damaged")

        // A binary frame's declared header length already identifies the body.
        // Payload bytes resembling CRLF must not be silently removed.
        let crlfPayload = Data([13, 10, 0xFF, 0xFB, 0x00])
        let framed = frame(header: header, payload: crlfPayload)
        try require(OnlineTTSService.extractAudioChunk(from: framed) == crlfPayload, "leading payload CRLF stripped")
        let prefixed = Data([1, 2, 3]) + framed
        try require(OnlineTTSService.extractAudioChunk(from: prefixed.dropFirst(3)) == crlfPayload, "frame parsing assumes zero-based Data indices")

        try require(OnlineTTSService.extractAudioChunk(from: frame(header: "Path:audio.metadata\r\n", payload: Data("{}".utf8))) == nil, "metadata accepted as audio")
        try require(OnlineTTSService.extractAudioChunk(from: frame(header: header, payload: Data())) == nil, "empty audio accepted")
        try require(OnlineTTSService.extractAudioChunk(from: Data()) == nil, "empty frame accepted")
        try require(OnlineTTSService.extractAudioChunk(from: Data([0])) == nil, "truncated length prefix accepted")
        try require(OnlineTTSService.extractAudioChunk(from: Data([0, 10, 1, 2])) == nil, "truncated header accepted")
        try require(OnlineTTSService.extractAudioChunk(from: Data([0, 1, 0xFF, 0xFF])) == nil, "invalid UTF-8 header accepted")
    }

    static func testCancellation() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw ProtocolTestFailure(message: "test runner must provide its temporary directory")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("cancelled.mp3")
        let service = OnlineTTSService()
        let cancelled = Task {
            // Cancel before synthesis starts. This must fail before opening the
            // socket, and cancellation must not become a network/fallback error.
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await service.synthesize(text: "Cancellation fixture", voice: "en-US-JennyNeural", outputURL: output)
                throw ProtocolTestFailure(message: "cancelled synthesis returned audio")
            } catch is CancellationError {
                try require(!FileManager.default.fileExists(atPath: output.path), "cancelled audio was written")
            }
        }
        try await cancelled.value
    }
}

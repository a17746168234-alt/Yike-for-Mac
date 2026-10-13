import Foundation
import Translation

enum TranslationFailure: LocalizedError, Equatable {
    case offline, timeout, invalidKey, quota, rateLimited, server(Int), invalidResponse, unsupportedLanguages
    var errorDescription: String? {
        switch self {
        case .offline: return "网络未连接，请联网后重试。识别文字已保留。"
        case .timeout: return "请求超时，已重试一次。请稍后重试或切换翻译引擎。"
        case .invalidKey: return "DeepL 密钥无效或无权限，请在引擎菜单中更新密钥。"
        case .quota: return "DeepL 本月字符额度已用完，可切换 Apple 翻译。"
        case .rateLimited: return "DeepL 请求过于频繁，请稍后再试。"
        case .server(let code): return "DeepL 服务暂时异常（\(code)），请稍后重试。"
        case .invalidResponse: return "翻译服务返回了不完整的结果，请重试。"
        case .unsupportedLanguages: return "这组语言暂不可用，请更换语言或切换翻译引擎。"
        }
    }

    static func message(for error: Error) -> String {
        if let failure = error as? TranslationFailure { return failure.localizedDescription }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return TranslationFailure.offline.localizedDescription
            case .timedOut: return "请求超时，请检查网络后重试。"
            case .cancelled: return "翻译已取消，识别文字已保留。"
            default: return "网络请求失败（\(error.code.rawValue)），请检查网络后重试。"
            }
        }
        if error is CancellationError { return "翻译已取消，识别文字已保留。" }
        return error.localizedDescription
    }
}

struct DeepLClient {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)
    let apiKey: String
    var transport: Transport = { try await URLSession.shared.data(for: $0) }
    var retryDelay: () async throws -> Void = { try await Task.sleep(for: .milliseconds(400)) }

    func translate(_ texts: [String], source: String, target: String) async throws -> [String] {
        let sources = ["en": "EN", "zh-CN": "ZH", "ja": "JA", "ko": "KO", "de": "DE", "fr": "FR"]
        let targets = ["en": "EN-US", "zh-CN": "ZH-HANS", "ja": "JA", "ko": "KO", "de": "DE", "fr": "FR"]
        guard let source = sources[source], let target = targets[target] else { throw TranslationFailure.unsupportedLanguages }
        var results: [String] = []
        // Bound each request by bytes as well as item count. Each OCR region keeps its result index.
        var batch: [String] = []
        for text in texts {
            if !batch.isEmpty && (batch.count == 40 || batch.reduce(0, { $0 + $1.utf8.count }) + text.utf8.count > 100_000) {
                results += try await send(batch, source: source, target: target)
                batch = []
            }
            batch.append(text)
        }
        if !batch.isEmpty { results += try await send(batch, source: source, target: target) }
        return results
    }

    private func send(_ texts: [String], source: String, target: String) async throws -> [String] {
        var request = URLRequest(url: URL(string: "https://api-free.deepl.com/v2/translate")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": texts, "source_lang": source, "target_lang": target])
        for attempt in 0...1 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await transport(request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw TranslationFailure.invalidResponse }
                switch http.statusCode {
                case 200: break
                case 401, 403: throw TranslationFailure.invalidKey
                case 456: throw TranslationFailure.quota
                case 429: throw TranslationFailure.rateLimited
                default: throw TranslationFailure.server(http.statusCode)
                }
                struct Payload: Decodable {
                    struct Item: Decodable { let text: String }
                    let translations: [Item]
                }
                guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
                      payload.translations.count == texts.count,
                      payload.translations.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw TranslationFailure.invalidResponse
                }
                return payload.translations.map(\.text)
            } catch let error as URLError where error.code == .timedOut {
                guard attempt == 0 else { throw TranslationFailure.timeout }
                try Task.checkCancellation()
                try await retryDelay()
            }
        }
        throw TranslationFailure.timeout
    }
}

@available(macOS 15.0, *)
enum AppleLanguagePreparation {
    @MainActor
    static func prepare(_ session: TranslationSession, source: String, target: String,
                        status: (String) -> Void) async throws {
        let locales = ["en": "en", "zh-CN": "zh-Hans", "ja": "ja", "ko": "ko", "de": "de", "fr": "fr"]
        guard let source = locales[source], let target = locales[target], source != target else {
            throw TranslationFailure.unsupportedLanguages
        }
        try Task.checkCancellation()
        status("正在准备 Apple 翻译；如需语言包，请确认系统下载提示…")
        // The public API exposes completion, not byte or percentage progress.
        do {
            try await session.prepareTranslation()
        } catch {
            throw ApplePreparationFailure(underlying: error)
        }
        try Task.checkCancellation()
        status("语言包已就绪，正在翻译…")
    }
}

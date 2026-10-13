import Foundation
import Translation

/// User-facing guidance stays separate from translated text and history.
struct TranslationDiagnostic: Equatable {
    enum Engine: String { case apple = "Apple 翻译", deepl = "DeepL 翻译" }
    let engine: Engine
    let reason: String
    let recovery: String
    var technicalDetail: String? = nil
    var title: String { "\(engine.rawValue)未完成" }
    var message: String { "原因：\(reason)\n解决方法：\(recovery)" }

    static let appleSystemRequired = Self(
        engine: .apple,
        reason: "当前 macOS 版本不支持 Yike 使用的 Apple 系统翻译功能。",
        recovery: "打开“系统设置 → 通用 → 软件更新”，检查能否升级至 macOS 15 或以上；暂时无法升级时，请设置 DeepL API Free 密钥并切换引擎。")
    static let missingDeepLKey = Self(
        engine: .deepl,
        reason: "这台电脑尚未设置 DeepL API Free 密钥。",
        recovery: "点击“设置 DeepL 密钥”填入你自己的 API Free 密钥，再重新翻译。密钥不会随安装包分享给其他人。")

    static func stalled(stage: String) -> Self {
        Self(engine: .apple, reason: "Apple 系统翻译在“\(stage)”阶段长时间没有完成，尚不能确定具体原因。",
             recovery: "检查是否有等待确认的语言包下载提示，并确认网络和磁盘空间。完成下载后重试；仍无响应时退出并重新打开 Yike，或切换 DeepL。原文和已识别文字会保留。")
    }

    static func explain(_ error: Error, engine: Engine) -> Self {
        let preparation = error as? ApplePreparationFailure
        let underlying = preparation?.underlying ?? error
        let ns = underlying as NSError
        func issue(_ reason: String, _ recovery: String, code: String? = nil) -> Self {
            Self(engine: engine, reason: reason, recovery: recovery, technicalDetail: code)
        }
        let retry = engine == .apple
            ? "确认语言包下载提示后重试；仍失败时退出并重新打开 Yike，或切换 DeepL。"
            : "稍后重试，或切换 Apple 翻译（需要 macOS 15 及以上及对应语言包）。"

        if let failure = underlying as? TranslationFailure {
            switch failure {
            case .offline:
                return issue("网络未连接。", "连接可用网络后重试。Apple 翻译首次使用也需要联网下载语言包。")
            case .timeout:
                return issue("DeepL 请求超时，重试一次后仍未收到结果。", "检查网络或代理是否能访问 DeepL API，再稍后重试。", code: "请求超时")
            case .invalidKey:
                return issue("DeepL 拒绝了密钥，密钥可能无效、已失效，或不属于 API Free 服务。", "点击“设置 DeepL 密钥”重新填写 API Free 密钥；DeepL 网页版订阅不等于 API 权限。", code: "HTTP 401 / 403")
            case .quota:
                return issue("DeepL 返回额度耗尽，当前账户已达到翻译额度或用量上限。", "到 DeepL 账户检查额度和用量限制；等待额度恢复，或切换 Apple 翻译。", code: "HTTP 456")
            case .rateLimited:
                return issue("DeepL 请求过于频繁，服务暂时限制了请求。", "稍等一会再试，避免连续点击翻译；多人共用密钥也可能触发限制。", code: "HTTP 429")
            case .server(let code):
                if code == 400 {
                    return issue("DeepL 未接受本次翻译请求。", "手动选择正确的原文和目标语言，用一小段普通文字重试；仍失败时请反馈此错误代码。", code: "HTTP 400")
                }
                if code == 413 {
                    return issue("本次内容超过 DeepL 单次请求的大小限制。", "将长文本分成较短段落；图片可减少一次翻译的文字区域，再重试。", code: "HTTP 413")
                }
                return issue(code >= 500 ? "DeepL 服务暂时发生异常。" : "DeepL 未接受请求，尚不能确定具体原因。", retry, code: "HTTP \(code)")
            case .invalidResponse:
                return issue("翻译服务没有返回完整、可用的译文。", "用较短文本重试；如果仍失败，请切换引擎并反馈问题。")
            case .unsupportedLanguages:
                return issue("当前选择的语言组合不可用，或原文和目标语言相同。", "手动选择不同的原文和目标语言，例如“英语 → 中文”，再重试。")
            }
        }

        if underlying is CancellationError || (ns.domain == NSURLErrorDomain && ns.code == URLError.cancelled.rawValue) {
            return issue("本次翻译或语言包准备已取消。", "点击“重新尝试”；如出现系统语言包下载提示，请允许下载并等待完成。")
        }
        if ns.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: ns.code)
            switch code {
            case .notConnectedToInternet:
                return issue("网络未连接，无法完成在线请求或语言包下载。", "连接可用网络后重试。已装好语言包的 Apple 翻译可在本地运行。", code: "网络错误 \(ns.code)")
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
                return issue("无法连接到\(engine == .apple ? "Apple 相关服务" : "DeepL API")，可能是地址解析、网络或代理问题。", "检查网络和代理；可换一个可用网络重试。其他网站或另一个翻译引擎能用，并不代表此服务可连接。", code: "网络错误 \(ns.code)")
            case .timedOut:
                return issue("等待\(engine.rawValue)响应超时。", "检查网络；Apple 首次使用请先完成语言包下载，再重试。", code: "网络错误 \(ns.code)")
            case .networkConnectionLost:
                return issue("请求过程中网络连接中断。", "网络恢复稳定后重新尝试。", code: "网络错误 \(ns.code)")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return issue("无法建立安全连接，证书或 TLS 校验失败。", "检查电脑日期时间及代理设置，再重试；不要关闭证书校验。", code: "网络错误 \(ns.code)")
            default:
                return issue("网络请求未能完成。", "检查网络和代理后重试；仍失败时请反馈下方错误代码。", code: "网络错误 \(ns.code)")
            }
        }
        if engine == .apple, #available(macOS 15.0, *) {
            if #available(macOS 26.0, *) {
                if TranslationError.notInstalled ~= underlying {
                    return issue("此语言组合需要的 Apple 语言包尚未安装。", "保持联网，点击“重新尝试”并允许系统下载语言包。每台 Mac 都需要单独下载；同时确认磁盘有可用空间。")
                }
                if TranslationError.alreadyCancelled ~= underlying {
                    return issue("Apple 翻译会话已经取消。", "点击“重新尝试”建立新会话；仍失败时重新打开 Yike。")
                }
            }
            switch underlying {
            case TranslationError.unsupportedSourceLanguage, TranslationError.unsupportedTargetLanguage, TranslationError.unsupportedLanguagePairing:
                return issue("Apple 系统不支持当前选择的语言或语言组合。", "手动选择“英语 → 中文”等可用组合；检查 macOS 更新，或切换 DeepL。")
            case TranslationError.unableToIdentifyLanguage:
                return issue("Apple 无法识别这段文字的语言。", "手动选择原文语言，输入完整的一句话后重试；图片请先检查识别文字是否正确。")
            case TranslationError.nothingToTranslate:
                return issue("Apple 没有找到可翻译的文字。", "输入实际文字，避免只有空格、数字或符号；图片请先检查和修正识别结果。")
            default: break
            }
        }
        let stage = preparation == nil ? "" : "，发生在语言包准备阶段"
        return issue("\(engine.rawValue)未能完成\(stage)，系统未提供可确定的失败原因。",
                     engine == .apple ? "先检查语言包下载提示、网络和磁盘空间，再重新打开 Yike 重试；仍失败时检查 macOS 更新，或切换 DeepL。请将下方错误代码反馈给开发者。" : retry,
                     code: "\(ns.domain) / \(ns.code)")
    }
}

struct ApplePreparationFailure: Error {
    let underlying: Error
}

/// Bounds a stalled system session without treating a timeout as a known root cause.
@MainActor
final class TranslationWatchdog {
    private var task: Task<Void, Never>?
    func cancel() { task?.cancel(); task = nil }
    func arm(seconds: Double, onTimeout: @escaping @MainActor () -> Void) {
        cancel()
        task = Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard !Task.isCancelled else { return }
            onTimeout()
        }
    }
}

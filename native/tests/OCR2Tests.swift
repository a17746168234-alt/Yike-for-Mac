import AppKit
import CoreImage
import Foundation
import Translation

struct OCR2TestFailure: Error, CustomStringConvertible { let description: String }
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw OCR2TestFailure(description: message) }
}

actor RequestProbe {
    var count = 0
    func hit() -> Int { count += 1; return count }
}

@main
struct OCR2Tests {
    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        if CommandLine.arguments.contains("--generate-fixtures") {
            try generateFixtures(root)
            return
        }
        try documentTests()
        try layoutTests()
        try await networkTests()
        try await diagnosticTests()
        try fixtureTests(root)
        try renderingTests(root)
        print("OCR2Tests: document, layout, network and fixed-image regression suites passed")
    }

    static func documentTests() throws {
        let box = CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.4)
        let low = RecognizedImageBlock(text: "hello world", boundingBox: box, confidence: 0.6,
                                       candidates: ["hello world", "hello word"])
        try check(low.needsReview, "low confidence must be flagged")
        var edited = low; edited.reviewed = true
        try check(!edited.needsReview, "user confirmation must remove warning")
        let data = try JSONEncoder().encode(low)
        try check(tryDecoded(data) == low, "candidate/confidence must survive coding")
        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy.removeValue(forKey: "confidence"); legacy.removeValue(forKey: "candidates")
        legacy.removeValue(forKey: "reviewed")
        let restored = try JSONDecoder().decode(RecognizedImageBlock.self, from: JSONSerialization.data(withJSONObject: legacy))
        try check(restored.text == low.text && !restored.needsReview, "Build 58 data must still decode")
        for axis in OCRDocument.SplitAxis.allCases {
            let parts = OCRDocument.split(low, at: 5, axis: axis)
            try check(parts.count == 2 && parts[0].text == "hello" && parts[1].text == "world", "split preserves both strings")
            try check(parts[0].id != parts[1].id, "split IDs must differ")
            let union = parts[0].boundingBox.union(parts[1].boundingBox)
            try check(abs(union.width - box.width) < 0.00001 && abs(union.height - box.height) < 0.00001, "split must preserve bounds")
            let merged = OCRDocument.merge(parts.reversed())!
            try check(merged.text == (axis == .rows ? "hello\nworld" : "hello world"), "merge preserves reading order and line continuity")
        }
        try check(OCRDocument.split(low, at: 0, axis: .rows).count == 1, "invalid split must not delete text")
        let cjk = RecognizedImageBlock(text: "你好👨‍👩‍👧‍👦世界", boundingBox: box)
        let split = OCRDocument.split(cjk, at: 3, axis: .columns)
        try check(split[0].text == "你好👨‍👩‍👧‍👦", "split must preserve grapheme clusters")
        let added = OCRDocument.normalizedRect(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 90, y: 70), imageRect: CGRect(x: 0, y: 0, width: 100, height: 100))!
        try check(abs(added.minY - 0.3) < 0.00001 && abs(added.width - 0.8) < 0.00001, "UI top-left coordinates must convert to Vision bottom-left")
        try check(OCRDocument.normalizedRect(from: .zero, to: CGPoint(x: 2, y: 2), imageRect: box) == nil, "tiny/outside drag rejected")
        let alternative = OCRDocument.merge([low, low], reviewed: false)!
        try check(alternative.needsReview && (alternative.candidates?.count ?? 0) > 1, "automatic merge must retain uncertainty and alternatives")
        print("PASS document: coding, confidence, alternatives, add, split, merge, Unicode")
    }

    static func tryDecoded(_ data: Data) -> RecognizedImageBlock? { try? JSONDecoder().decode(RecognizedImageBlock.self, from: data) }

    static func layoutTests() throws {
        for text in ["This is a substantially longer English translation that must wrap into a small box.",
                     "这是一段比原文长很多的中文译文，必须自动缩小字号，避免文字超出原来的区域。",
                     "SUPERCALIFRAGILISTICEXPIALIDOCIOUS0123456789", "第一行\n第二行\n第三行"] {
            for size in [CGSize(width: 130, height: 42), CGSize(width: 60, height: 25), CGSize(width: 300, height: 80)] {
                let font = TextLayout.fontSize(for: text, in: size, preferred: 42)
                try check(font <= 42 && font >= 1, "fit font out of range")
                try check(TextLayout.fits(text, in: size, fontSize: font), "text overflow at fitted font: \(text)")
            }
        }
        print("PASS layout: 12 CJK/Latin/multiline/unbroken-token fits")
    }

    static func networkTests() async throws {
        let url = URL(string: "https://example.invalid")!
        let success = Data(#"{"translations":[{"text":"你好"}]}"#.utf8)
        let probe = RequestProbe()
        let retry = DeepLClient(apiKey: "fixture", transport: { _ in
            if await probe.hit() == 1 { throw URLError(.timedOut) }
            return (success, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, retryDelay: {})
        let result = try await retry.translate(["hello"], source: "en", target: "zh-CN")
        try check(result == ["你好"], "timeout retry did not return result")
        let retryCount = await probe.count
        try check(retryCount == 2, "timeout must retry exactly once")
        for (code, expected) in [(403, TranslationFailure.invalidKey), (456, .quota), (429, .rateLimited), (503, .server(503))] {
            let probe = RequestProbe()
            let client = DeepLClient(apiKey: "fixture", transport: { _ in
                _ = await probe.hit()
                return (Data(), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }, retryDelay: {})
            do { _ = try await client.translate(["hello"], source: "en", target: "zh-CN"); throw OCR2TestFailure(description: "HTTP \(code) accepted") }
            catch let error as TranslationFailure { try check(error == expected, "HTTP mapping wrong") }
            let count = await probe.count
            try check(count == 1, "non-timeout error must not retry")
        }
        let timeoutProbe = RequestProbe()
        let timeout = DeepLClient(apiKey: "fixture", transport: { _ in _ = await timeoutProbe.hit(); throw URLError(.timedOut) }, retryDelay: {})
        do { _ = try await timeout.translate(["hello"], source: "en", target: "zh-CN"); throw OCR2TestFailure(description: "timeout accepted") }
        catch let error as TranslationFailure { try check(error == .timeout, "second timeout must stop") }
        let timeoutCount = await timeoutProbe.count
        try check(timeoutCount == 2, "retry exceeded limit")
        let broken = DeepLClient(apiKey: "fixture", transport: { _ in
            (Data(#"{"translations":[]}"#.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        do { _ = try await broken.translate(["hello"], source: "en", target: "zh-CN"); throw OCR2TestFailure(description: "incomplete result accepted") }
        catch let error as TranslationFailure { try check(error == .invalidResponse, "invalid response not classified") }
        try check(TranslationFailure.message(for: URLError(.notConnectedToInternet)).contains("网络未连接"), "offline error not classified")
        let cancelledProbe = RequestProbe()
        let cancelled = DeepLClient(apiKey: "fixture", transport: { _ in
            _ = await cancelledProbe.hit(); throw URLError(.timedOut)
        }, retryDelay: { throw CancellationError() })
        do { _ = try await cancelled.translate(["hello"], source: "en", target: "zh-CN"); throw OCR2TestFailure(description: "cancellation ignored") }
        catch is CancellationError { }
        let cancelledCount = await cancelledProbe.count
        try check(cancelledCount == 1, "cancelled retry must not send again")
        let batchProbe = RequestProbe()
        let batchClient = DeepLClient(apiKey: "fixture", transport: { request in
            _ = await batchProbe.hit()
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let texts = body["text"] as! [String]
            return (try JSONSerialization.data(withJSONObject: ["translations": texts.map { ["text": $0] }]),
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let many = (0..<85).map { "region-\($0)" }
        let batched = try await batchClient.translate(many, source: "en", target: "zh-CN")
        let batchCount = await batchProbe.count
        try check(batched == many && batchCount == 3, "batch order or request bounds changed")
        print("PASS network: retry cap, cancellation, 85-region batch order, HTTP errors, response completeness, offline mapping (mock transport)")
    }

    @MainActor
    static func diagnosticTests() async throws {
        let dns = TranslationDiagnostic.explain(URLError(.cannotFindHost), engine: .deepl)
        try check(dns.reason.contains("无法连接") && !dns.reason.contains("网络未连接"), "DNS failure must not claim offline")
        let quota = TranslationDiagnostic.explain(TranslationFailure.quota, engine: .deepl)
        try check(quota.technicalDetail == "HTTP 456" && quota.recovery.contains("账户"), "quota guidance missing")
        let invalidKey = TranslationDiagnostic.explain(TranslationFailure.invalidKey, engine: .deepl)
        try check(invalidKey.recovery.contains("API Free") && invalidKey.recovery.contains("网页版"), "key recovery must distinguish API from web subscription")
        let badRequest = TranslationDiagnostic.explain(TranslationFailure.server(400), engine: .deepl)
        try check(!badRequest.reason.contains("服务暂时发生异常"), "HTTP 400 must not be called a server outage")
        let tooLarge = TranslationDiagnostic.explain(TranslationFailure.server(413), engine: .deepl)
        try check(tooLarge.recovery.contains("分成"), "large request needs split guidance")
        let unknown = TranslationDiagnostic.explain(NSError(domain: "ExampleUnknown", code: 73), engine: .apple)
        try check(unknown.reason.contains("未提供可确定") && unknown.technicalDetail == "ExampleUnknown / 73", "unknown errors must preserve uncertainty and code")
        let preparation = TranslationDiagnostic.explain(ApplePreparationFailure(underlying: NSError(domain: "ExamplePrepare", code: 9)), engine: .apple)
        try check(preparation.reason.contains("语言包准备") && preparation.technicalDetail == "ExamplePrepare / 9", "preparation context lost")
        let wrappedOffline = TranslationDiagnostic.explain(ApplePreparationFailure(underlying: URLError(.notConnectedToInternet)), engine: .apple)
        try check(wrappedOffline.reason.contains("网络未连接"), "wrapped URL failure must retain classification")
        if #available(macOS 15.0, *) {
            for error in [TranslationError.unsupportedSourceLanguage, .unsupportedTargetLanguage, .unsupportedLanguagePairing] {
                let issue = TranslationDiagnostic.explain(error, engine: .apple)
                try check(issue.reason.contains("不支持") && issue.recovery.contains("手动"), "Apple unsupported language needs actionable guidance")
            }
            let language = TranslationDiagnostic.explain(TranslationError.unableToIdentifyLanguage, engine: .apple)
            try check(language.recovery.contains("原文语言"), "language identification needs manual language instruction")
            if #available(macOS 26.0, *) {
                let missing = TranslationDiagnostic.explain(ApplePreparationFailure(underlying: TranslationError.notInstalled), engine: .apple)
                try check(missing.reason.contains("尚未安装") && missing.recovery.contains("每台 Mac"), "missing model must explain per-machine download")
                let cancelled = TranslationDiagnostic.explain(TranslationError.alreadyCancelled, engine: .apple)
                try check(cancelled.recovery.contains("新会话"), "cancelled session guidance missing")
            }
        }
        let watchdog = TranslationWatchdog()
        var fired = 0
        watchdog.arm(seconds: 0.01) { fired += 100 }
        watchdog.cancel()
        try await Task.sleep(for: .milliseconds(50))
        try check(fired == 0, "cancelled watchdog must not overwrite results")
        watchdog.arm(seconds: 1) { fired += 100 }
        await withCheckedContinuation { continuation in
            watchdog.arm(seconds: 0.01) { fired += 1; continuation.resume() }
        }
        watchdog.cancel()
        try check(fired == 1, "rearming must replace earlier watchdog")
        print("PASS diagnostics: Apple SDK errors, download context, DNS vs offline, HTTP guidance, unknown codes, watchdog cancellation/rearming")
    }

    static let fixtureNames = ["english", "chinese", "rotated", "skewed", "low-contrast", "blank"]
    static let english = "HELLO WORLD\nOCR TEST 2026"
    static let chinese = "你好世界\n文字识别测试"

    @MainActor
    static func generateFixtures(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in fixtureNames {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 480,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: 1200, height: 480)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill(); NSBezierPath(rect: CGRect(x: 0, y: 0, width: 1200, height: 480)).fill()
            if name != "blank" {
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 76, weight: .medium),
                    .foregroundColor: NSColor(calibratedWhite: name == "low-contrast" ? 0.80 : 0.05, alpha: 1)]
                ((name == "chinese" ? chinese : english) as NSString).draw(in: CGRect(x: 80, y: 100, width: 1040, height: 280), withAttributes: attributes)
            }
            NSGraphicsContext.restoreGraphicsState()
            var image = CIImage(cgImage: rep.cgImage!)
            if name == "rotated" { image = image.oriented(.right) }
            if name == "skewed" { image = image.transformed(by: CGAffineTransform(rotationAngle: .pi / 45)) }
            let rendered = try OCRService.render(image)
            let output = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:])!
            try output.write(to: root.appendingPathComponent(name + ".png"))
        }
        print("Generated 6 fixed OCR fixtures")
    }

    static func normalized(_ value: String) -> String { value.uppercased().filter { !$0.isWhitespace && !$0.isPunctuation } }
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for (i, lhs) in a.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, rhs) in b.enumerated() { next[j + 1] = min(next[j] + 1, row[j + 1] + 1, row[j] + (lhs == rhs ? 0 : 1)) }
            row = next
        }
        return row.last ?? 0
    }

    static func fixtureTests(_ root: URL) throws {
        print("fixture,baseline_CER,OCR2_CER,adjustments")
        for name in fixtureNames {
            let url = root.appendingPathComponent(name + ".png")
            let baseline = try OCRService.recognize(at: url, preprocess: false)
            let result = try OCRService.recognize(at: url)
            if name == "rotated" {
                try check(result.image.width > result.image.height, "rotated fixture was not restored to landscape orientation")
            }
            if name == "blank" { try check(result.blocks.isEmpty, "blank fixture hallucinated text"); continue }
            let expected = normalized(name == "chinese" ? chinese : english)
            let before = Double(distance(expected, normalized(baseline.blocks.map(\.text).joined()))) / Double(expected.count)
            let after = Double(distance(expected, normalized(result.blocks.map(\.text).joined()))) / Double(expected.count)
            print("\(name),\(before),\(after),\(result.adjustments.joined(separator: ";"))")
            try check(after <= 0.15, "OCR CER above 15% for \(name): \(result.blocks.map(\.text))")
            try check(after <= before + 0.05, "preprocessing regressed \(name)")
            try check(result.blocks.allSatisfy { CGRect(x: 0, y: 0, width: 1, height: 1).contains($0.boundingBox) }, "OCR bounds outside processed image")
        }
    }

    @MainActor
    static func renderingTests(_ root: URL) throws {
        let blank = NSImage(contentsOf: root.appendingPathComponent("blank.png"))!
        let phrases = ["THIS LONG ENGLISH TRANSLATION MUST FIT INSIDE THE ORIGINAL TEXT REGION",
                       "这段中文译文比原文更长但是必须完整显示在文字区域里面"]
        for (index, phrase) in phrases.enumerated() {
            for style in ImageTranslationRenderStyle.allCases {
                let rendered = renderedTranslationImage(source: blank, edits: [EditableImageTranslationBlock(
                    originalText: "short", translatedText: phrase,
                    boundingBox: CGRect(x: 0.15, y: 0.3, width: 0.7, height: 0.25), fontScale: 2)], style: style)
                let bitmap = NSBitmapImageRep(data: rendered.tiffRepresentation!)!
                let recognized = try OCRService.observations(in: bitmap.cgImage!).compactMap { $0.topCandidates(1).first?.string }.joined()
                let error = Double(distance(normalized(phrase), normalized(recognized))) / Double(normalized(phrase).count)
                try check(error <= 0.05, "rendered translation missing or clipped: \(recognized)")
                if CommandLine.arguments.contains("--render-previews") {
                    let previewRoot = root.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                        .appendingPathComponent("work/ocr2-tests")
                    try bitmap.representation(using: .png, properties: [:])!.write(to: previewRoot.appendingPathComponent("layout-\(index)-\(style.rawValue).png"))
                }
            }
        }
        print("PASS rendering: complete long CJK/Latin text in natural/contrast output (Vision read-back)")
    }
}

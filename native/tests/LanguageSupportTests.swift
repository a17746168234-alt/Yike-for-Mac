import Foundation
import NaturalLanguage

@main
struct LanguageSupportTests {
    static func main() async throws {
        for (code, name, greeting) in [("de", "德语", "Guten Morgen! Wie geht es Ihnen heute?"), ("fr", "法语", "Bonjour ! Comment allez-vous aujourd’hui ?")] {
            precondition(concreteLanguages.contains(code) && sourceLanguagesWithAuto.contains(code))
            precondition(languageName(code) == name)
            precondition(speechLocales[code] != nil && appleTranslationLocales[code] == code)
            precondition(OnlineTTSService.voice(for: code, persona: .female) != nil)
            precondition(OnlineTTSService.voice(for: code, persona: .male) != nil)
            let data = try JSONSerialization.data(withJSONObject: ["result": ["language": code], "transcription": [["text": greeting]]])
            let speech = try LocalSpeechResult.parse(data)
            precondition(speech.language == code && speech.text == greeting)
            for (source, target) in [(code, "en"), ("en", code)] {
                let client = DeepLClient(apiKey: "fixture:fx", transport: { request in
                    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                    precondition(body["source_lang"] as? String == source.uppercased())
                    precondition(body["target_lang"] as? String == (target == "en" ? "EN-US" : target.uppercased()))
                    return (Data(#"{"translations":[{"text":"Test translation"}]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                })
                let result = try await client.translate([greeting], source: source, target: target)
                precondition(result == ["Test translation"])
            }
        }
        print("LanguageSupportTests passed: menus, locales, voice parsing, TTS and bidirectional DeepL requests")
    }
}

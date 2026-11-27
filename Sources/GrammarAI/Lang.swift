import Foundation
import NaturalLanguage

/// The language of a paragraph, detected on the Mac (NLLanguageRecognizer), passed to the model explicitly, and used
/// to skip languages the user doesn't want checked (Settings → Languages).
enum Lang {
    /// Languages offered in Settings → Languages (base codes), in display order.
    static let offered = ["en", "zh", "ko", "ja", "de", "fr", "es", "it", "pt", "nl"]

    /// "zh-Hans" → "zh".
    static func base(_ code: String) -> String { String(code.split(separator: "-").first ?? Substring(code)) }

    /// "Korean", "Chinese (Simplified)", "Chinese (Traditional)".
    static func name(_ code: String) -> String {
        switch code {
        case "zh-Hans": return "Chinese (Simplified)"
        case "zh-Hant": return "Chinese (Traditional)"
        default: return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        }
    }

    /// Detects a paragraph's language. Short or uncertain text falls back to `previous` (the paragraph before), then
    /// to the user's first writing language. `hints` weight the recognizer towards the user's languages.
    static func detect(_ text: String, previous: String? = nil, hints: [String] = Settings.shared.writingLanguages) -> String? {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        // CJK carries a lot per character: 4 Han/Hangul characters are as telling as ~12 Latin letters.
        let cjk = text.unicodeScalars.contains { isWide($0) }
        let enough = cjk ? letters >= 4 : letters >= 12
        // 1. Unbiased: a confident answer on enough text wins, even for a language the user didn't list
        //    (hints would pull German towards English, and the model would then be told the wrong language).
        let plain = NLLanguageRecognizer()
        plain.processString(text)
        if enough, let (lang, p) = plain.languageHypotheses(withMaximum: 1).first, lang != .undetermined, p >= 0.6 { return lang.rawValue }
        // 2. Short or uncertain: the paragraph before, then the user's languages as hints.
        if let previous { return previous }
        let r = NLLanguageRecognizer()
        var h: [NLLanguage: Double] = [:]
        for code in hints {
            if code == "zh" { h[.simplifiedChinese] = 1; h[.traditionalChinese] = 1 } else { h[NLLanguage(code)] = 1 }
        }
        r.languageHints = h
        r.processString(text)
        if let (lang, p) = r.languageHypotheses(withMaximum: 1).first, lang != .undetermined, p >= 0.5 { return lang.rawValue }
        return hints.first
    }

    /// Whether live checking should check text in this language (Settings → Languages).
    static func isChecked(_ code: String?, settings s: Settings = .shared) -> Bool {
        guard let code else { return true }
        let b = base(code)
        if s.writingLanguages.contains(b) { return true }
        return !offered.contains(b) && s.checkOtherLanguages
    }

    /// The line added to every instruction: the model is told the language instead of guessing it.
    static func line(_ code: String) -> String {
        "The text is \(name(code)) (\(code)). Correct it as \(name(code)), by that language's own rules; never translate it."
    }

    /// Language-specific rules, added only when that language is detected (overridable by `--eval`).
    static var blockOverrides: [String: String]?
    static func block(_ code: String) -> String? {
        if let o = blockOverrides { return o[code] ?? o[base(code)] }
        return blocks[code] ?? blocks[base(code)]
    }

    static let blocks: [String: String] = [
        "en": """
        English: contractions keep their apostrophe ("doesn't", never "dont"); keep the text's British or American spelling.
        """,
        "zh": """
        Chinese:
        - Common wrong characters are errors: 在/再, 的/得/地, 做/作, 已/以, 必须/必需, 象/像, and similar-looking or same-sounding characters (e.g. 以经 → 已经).
        - Wrong measure words are errors (三个书 → 三本书, 一只汽车 → 一辆汽车).
        - In Chinese sentences, half-width punctuation (, . ? ! : ;) should be full-width (，。？！：；); don't change punctuation inside English or code.
        - Keep Simplified or Traditional characters exactly as written; never convert between them.
        - Casual or internet style (哈哈, 笑死, 吧, missing final punctuation in chat) and English words mixed into Chinese (meeting, bug, code) are not errors.
        """,
        "ko": """
        Korean:
        - Spacing (띄어쓰기) is the most common error: bound nouns and auxiliaries are written apart (할 수 있다, 올 것 같다, 이번 주), particles are attached to their word. For a spacing error, the span must include the neighbouring characters and the fix shows the corrected spacing (span "할수있다" → fix "할 수 있다").
        - Spelling (맞춤법): e.g. 어떻해 → 어떻게, 뵈요 → 봬요, 않 돼 → 안 돼, 몇일 → 며칠, 웬일, 금세, 할게요.
        - Particles must match the preceding syllable: 은/는, 이/가, 을/를, 와/과.
        - Keep the speech level exactly as written (해요체, 합니다체 or 반말) and keep honorific choices; never make the text more or less polite.
        - Casual chat (ㅋㅋ, 좀만, 반말) and English words mixed into Korean are not errors.
        """,
    ]

    /// East Asian wide characters (two columns in a monospaced editor): Hangul, CJK ideographs and punctuation,
    /// kana, full-width forms, and most emoji.
    static func isWide(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}

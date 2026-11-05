// Migrated from the validated macOS lens prototype.
import AppKit
import NaturalLanguage

struct FocusedPassage {
    let anchor: String
    let sentence: String
    let focusLine: String
    let focusWordIndex: Int
    let selectionFocusRowBox: CGRect?
    let maskedSentence: String
    let localContext: String
    let maskedLocalContext: String
    let microContext: String
    let maskedMicroContext: String
    let prefixContext: String
    let maskedPrefixContext: String
    let literalTranslation: String?
    let distance: CGFloat
}

let focusMarker = "⟦X⟧"
let relativeTimeRegex = try! NSRegularExpression(
    pattern: "\\b([0-9]+)?\\s*(seconds?|minutes?|hours?|days?|weeks?|months?|years?)\\s*ago\\b",
    options: [.caseInsensitive])
func relativeTimeChinese(_ source: String) -> String? {
    let range = NSRange(location: 0, length: (source as NSString).length)
    guard let match = relativeTimeRegex.firstMatch(in: source, range: range),
          match.range == range else { return nil }
    let count = match.range(at: 1).location == NSNotFound ? "" :
        (source as NSString).substring(with: match.range(at: 1))
    let unit = (source as NSString).substring(with: match.range(at: 2)).lowercased()
    let chinese: String
    if unit.hasPrefix("second") { chinese = "秒" }
    else if unit.hasPrefix("minute") { chinese = "分钟" }
    else if unit.hasPrefix("hour") { chinese = "小时" }
    else if unit.hasPrefix("day") { chinese = "天" }
    else if unit.hasPrefix("week") { chinese = "周" }
    else if unit.hasPrefix("month") { chinese = "个月" }
    else { chinese = "年" }
    return "\(count)\(chinese)前"
}

func cleanChineseTerm(_ text: String) -> String? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let scalars = Array(value.unicodeScalars)
    guard (1...8).contains(scalars.count), scalars.allSatisfy({
        (0x3400...0x9FFF).contains($0.value)
    }) else { return nil }
    return value
}

func translatedDifference(_ translated: String, _ masked: String,
                                  allowOneCharacterSuffix: Bool = false) -> String? {
    let source = Array(translated.trimmingCharacters(in: .whitespacesAndNewlines))
    let parts = masked.components(separatedBy: focusMarker)
    guard parts.count == 2 else { return nil }
    let left = Array(parts[0])
    let right = Array(parts[1])
    var prefix = 0
    while prefix < min(source.count, left.count), source[prefix] == left[prefix] { prefix += 1 }
    guard prefix == left.count else { return nil }
    var end = source.count
    if !right.isEmpty {
        let limit = min(12, right.count)
        var located: Int?
        let minimum = allowOneCharacterSuffix ? 1 : 2
        if limit >= minimum {
            for length in stride(from: limit, through: minimum, by: -1) {
                guard prefix + length <= source.count else { continue }
                for index in prefix...(source.count - length) {
                    if Array(source[index..<(index + length)]) == Array(right.prefix(length)) {
                        located = index
                        break
                    }
                }
                if located != nil { break }
            }
        }
        guard let located else { return nil }
        end = located
    }
    guard end > prefix else { return nil }
    return cleanChineseTerm(String(source[prefix..<end]))
}

func focusedChineseWord(full: String, masked: String,
                                local: String, maskedLocal: String,
                                direct: String?) -> String? {
    // The standalone translation is useful only when both contextual outputs
    // contain the same Chinese word and both masked outputs lose it.
    if !masked.isEmpty, !maskedLocal.isEmpty,
       let direct = direct.flatMap(cleanChineseTerm),
       full.contains(direct), local.contains(direct),
       !masked.contains(direct), !maskedLocal.contains(direct) {
        return direct
    }
    if let inferred = translatedDifference(local, maskedLocal),
       full.contains(inferred), !masked.contains(inferred) {
        return inferred
    }
    if let inferred = translatedDifference(full, masked),
       local.contains(inferred), !maskedLocal.contains(inferred) {
        return inferred
    }
    return nil
}

func sharedContextTerm(full: String, local: String, maskedLocal: String,
                               micro: String, maskedMicro: String,
                               prefix: String, maskedPrefix: String) -> String? {
    let characters = Array(prefix)
    guard characters.count >= 2 else { return nil }
    for length in stride(from: min(8, characters.count), through: 2, by: -1) {
        for start in 0...(characters.count - length) {
            let candidate = String(characters[start..<(start + length)])
            guard cleanChineseTerm(candidate) != nil,
                  local.contains(candidate), micro.contains(candidate),
                  !maskedLocal.contains(candidate), !maskedMicro.contains(candidate),
                  !maskedPrefix.contains(candidate),
                  candidate.last.map({ full.contains($0) }) == true else { continue }
            return candidate
        }
    }
    return nil
}

func dictionaryTerm(_ direct: String?) -> String? {
    guard let direct else { return nil }
    if let clean = cleanChineseTerm(direct) { return clean }
    // Apple's standalone gloss can be a template such as “在...以前”.
    let parts = direct.replacingOccurrences(of: "……", with: "...")
        .replacingOccurrences(of: "…", with: "...")
        .components(separatedBy: "...")
    guard parts.count > 1 else { return nil }
    return parts.reversed().compactMap(cleanChineseTerm).first
}

func translationFallback(_ text: String?, maxLength: Int) -> String? {
    guard let text else { return nil }
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count <= maxLength,
          value.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }),
          !value.contains(focusMarker) else { return nil }
    return value
}

func resolveFocus(anchor: String, full: String, masked: String,
                          local: String, maskedLocal: String,
                          sourceLocal: String,
                          sourceMicro: String,
                          micro: String, maskedMicro: String,
                          sourcePrefix: String,
                          prefix: String, maskedPrefix: String,
                          direct: String?) -> FocusedTranslation {
    let normalized = anchor.lowercased().replacingOccurrences(of: "’", with: "'")
    let following = sourceMicro.split(separator: " ").dropFirst().prefix(2)
    let progressive = following.contains { $0.lowercased().hasSuffix("ing") }
    if progressive && ["am", "is", "are", "was", "were"].contains(normalized) {
        return FocusedTranslation(chinese: "正在", basis: "进行时")
    }
    // An -ing noun after a possessive ("company's working group") is not a contraction.
    let objectAfterParticiple = following.dropFirst().first.map {
        ["me", "you", "him", "her", "it", "us", "them"].contains($0.lowercased())
    } ?? false
    if progressive && objectAfterParticiple && normalized.hasSuffix("'s") {
        return FocusedTranslation(chinese: "此处 ’s 表示“正在”", basis: "缩写语法")
    }
    if normalized == "it's", full.contains("是"), local.contains("是") {
        return FocusedTranslation(chinese: "是", basis: "缩写语法")
    }
    let normalizedLocal = sourceLocal.lowercased()
        .replacingOccurrences(of: "’", with: "'")
    if normalized == "after",
       normalizedLocal.range(
        of: "\\b(?:i|you|he|she|we|they)(?:\\s+(?:am|are|is|was|were)|'(?:m|re|s))\\s+after\\b",
        options: .regularExpression) != nil {
        return FocusedTranslation(chinese: "想要", basis: "短语语义")
    }
    if let word = focusedChineseWord(full: full, masked: masked,
                                     local: local, maskedLocal: maskedLocal,
                                     direct: direct),
       !(normalized.hasSuffix("ing") && ["在", "正", "着", "了"].contains(word)) {
        return FocusedTranslation(chinese: word, basis: "语境互证")
    }
    if let word = translatedDifference(micro, maskedMicro,
                                       allowOneCharacterSuffix: true),
       !maskedMicro.contains(word),
       (full.contains(word) || direct?.contains(word) == true) {
        return FocusedTranslation(chinese: word, basis: "邻近短语")
    }
    if let word = translatedDifference(prefix, maskedPrefix,
                                       allowOneCharacterSuffix: true),
       !maskedPrefix.contains(word),
       (full.contains(word) || direct?.contains(word) == true) {
        return FocusedTranslation(chinese: word, basis: "邻近短语")
    }
    if let word = sharedContextTerm(full: full, local: local,
                                    maskedLocal: maskedLocal, micro: micro,
                                    maskedMicro: maskedMicro, prefix: prefix,
                                    maskedPrefix: maskedPrefix) {
        return FocusedTranslation(chinese: word, basis: "短语互证")
    }
    let previous = sourcePrefix.split(separator: " ").dropLast().last.map(String.init) ?? ""
    if ["on", "in", "up", "out", "off", "for"].contains(normalized),
       previous.lowercased().hasSuffix("ing") {
        return FocusedTranslation(chinese: "随动词合译", basis: "语法作用")
    }
    if ["the", "a", "an"].contains(normalized) {
        return FocusedTranslation(chinese: "限定词，常省译", basis: "语法作用")
    }
    if normalized.range(of: "^(?:it|he|she|that)'s$", options: .regularExpression) != nil,
       local.contains("是"), micro.contains("是") {
        return FocusedTranslation(chinese: "是", basis: "语法作用")
    }
    if anchor.count == 1, let value = anchor.unicodeScalars.first?.value,
       (65...90).contains(value) {
        return FocusedTranslation(chinese: "字母 \(anchor)", basis: "字母名称")
    }
    // Alignment is a quality check, not a condition for showing a result.
    // Standalone glosses of short words can be ambiguous, so label them clearly.
    if let word = dictionaryTerm(direct),
       [full, local, micro].contains(where: { $0.contains(word) }) {
        return FocusedTranslation(chinese: word, basis: "单词参考")
    }
    for context in [full, local, micro] {
        if let phrase = translationFallback(context, maxLength: 80) {
            return FocusedTranslation(chinese: phrase, basis: "语境参考")
        }
    }
    if let word = translationFallback(direct, maxLength: 32) {
        return FocusedTranslation(chinese: word, basis: "直译参考")
    }
    return FocusedTranslation(chinese: nil, basis: "")
}

let proseCommentPrefix = try! NSRegularExpression(
    pattern: "^\\s*(?://+|#|/\\*+|\\*+)\\s*")
let proseCommentWords = try! NSRegularExpression(pattern: "[A-Za-z]+(?:['’][A-Za-z]+)?")

func proseCommentBodyRange(_ line: String) -> NSRange? {
    let source = line as NSString
    let whole = NSRange(location: 0, length: source.length)
    guard let prefix = proseCommentPrefix.firstMatch(in: line, range: whole) else { return nil }
    let body = NSRange(location: NSMaxRange(prefix.range),
                       length: source.length - NSMaxRange(prefix.range))
    let text = source.substring(with: body)
    let directive = text.trimmingCharacters(in: .whitespaces).lowercased()
    if source.substring(with: prefix.range).contains("#") &&
       ["include", "define", "import", "pragma", "endif"].contains(where: {
           directive.hasPrefix($0)
       }) { return nil }
    guard !text.contains("/") && !text.contains("\\") &&
          proseCommentWords.numberOfMatches(in: text,
                                            range: NSRange(location: 0,
                                                           length: (text as NSString).length)) >= 2
    else { return nil }
    return body
}

func looksLikePathOrCode(_ line: String) -> Bool {
    if proseCommentBodyRange(line) != nil { return false }
    if line.contains("/") || line.contains("\\") || line.contains("://") { return true }
    let lower = line.lowercased()
    return [".app", ".swift", ".mjs", ".js", ".json", ".py", ".md"].contains {
        lower.contains($0)
    }
}

func validatedEnglishWord(_ raw: String) -> String? {
    let word = raw.replacingOccurrences(of: "’", with: "'")
    guard word.range(of: "^(?:[A-Za-z]{2,24}|[A-Z]|[aAiI]|[A-Za-z]{2,20}'[A-Za-z]{1,5})$",
                     options: .regularExpression) != nil else { return nil }
    if word.count <= 2 {
        // An isolated capital is a letter name in prose (Q, U, ...), even
        // though the spell checker only knows A and I as one-letter words.
        if word.count == 1 && word.first?.isUppercase == true { return word }
        let shortWords: Set<String> = ["a", "i", "am", "an", "as", "at", "be", "by", "do",
                                       "go", "he", "hi", "if", "in", "is", "it", "me", "my",
                                       "no", "of", "oh", "on", "or", "so", "to", "up", "us", "we"]
        return shortWords.contains(word.lowercased()) ? word : nil
    }
    let checker = NSSpellChecker.shared
    func isMisspelled(_ text: String) -> Bool {
        checker.checkSpelling(of: text, startingAt: 0, language: "en_US", wrap: false,
                              inSpellDocumentWithTag: 0, wordCount: nil).location != NSNotFound
    }
    if !isMisspelled(word) { return word }
    // Brand names and acronyms are valid visual targets even if the dictionary lacks them.
    if word.range(of: "^[A-Z][a-z]{4,23}$", options: .regularExpression) != nil ||
       word.range(of: "^[A-Z]{3,8}$", options: .regularExpression) != nil { return word }
    guard !word.contains("'") else { return nil }
    let suggestions = checker.guesses(forWordRange:
        NSRange(location: 0, length: (word as NSString).length), in: word,
        language: "en_US", inSpellDocumentWithTag: 0) ?? []
    // OCR can drop a faint initial glyph. Prefer an unambiguous leading-letter
    // completion (earch → search) before a same-length substitution (earth).
    let leadingCompletions = suggestions.filter { suggestion in
        suggestion.count == word.count + 1 &&
            String(suggestion.dropFirst()).caseInsensitiveCompare(word) == .orderedSame &&
            !isMisspelled(suggestion)
    }
    if leadingCompletions.count == 1 {
        return leadingCompletions[0]
    }
    // Only repair a single missing/incorrect character, such as moning → morning.
    return suggestions.prefix(3).first { suggestion in
        guard suggestion.count >= word.count,
              Array(word).prefix(2) == Array(suggestion).prefix(2) else { return false }
        let left = Array(word.lowercased())
        let right = Array(suggestion.lowercased())
        guard abs(left.count - right.count) <= 1,
              left.prefix(2) == right.prefix(2), !isMisspelled(suggestion) else { return false }
        var i = 0, j = 0, edits = 0
        while i < left.count && j < right.count {
            if left[i] == right[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if left.count >= right.count { i += 1 }
            if right.count >= left.count { j += 1 }
        }
        return edits + left.count - i + right.count - j == 1
    }
}

let clipboardWordRegex = try! NSRegularExpression(
    pattern: "[A-Za-z]+(?:['’][A-Za-z]+)?")

func clipboardWords(_ text: String) -> [String] {
    let source = text as NSString
    return clipboardWordRegex.matches(in: text,
                                      range: NSRange(location: 0, length: source.length)).map {
        source.substring(with: $0.range).lowercased()
            .replacingOccurrences(of: "’", with: "'")
    }
}

func englishDominant(_ text: String) -> Bool {
    let latin = text.unicodeScalars.filter {
        (65...90).contains($0.value) || (97...122).contains($0.value)
    }.count
    let han = text.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) }.count
    return han == 0 ? latin > 0 : latin >= max(12, han * 3)
}

private let punctuatedBlockSeamRegex = try! NSRegularExpression(
    pattern: "([a-z]{2,}[.?!][”\"'\\)]?)(?=[A-Z][a-z]{1,}|[A-Z]\\s)")

private let gluedBlockWordSeamRegex = try! NSRegularExpression(
    pattern: "\\b([A-Za-z][a-z]{1,22})([A-Z][a-z]{1,22})\\b(?=\\s+[A-Za-z])")

private let knownMixedCaseWords: Set<String> = [
    "iphone", "ipad", "ipod", "imac", "icloud", "ios", "macos", "watchos",
    "tvos", "visionos", "ebay", "email", "ecommerce", "youtube", "deepseek",
    "openai", "chatgpt", "github", "gitlab", "javascript", "typescript",
    "wordpress", "linkedin", "playstation", "mastercard", "paypal", "tiktok",
    "wechat", "whatsapp", "powerpoint", "onedrive", "garageband", "facetime",
    "macbook", "airpods", "easylens", "screencapturekit", "appkit", "swiftui",
    "webkit"
]

private let paragraphStarterWords: Set<String> = [
    "we", "you", "they", "he", "she", "it", "the", "this", "these", "that",
    "those", "in", "on", "at", "for", "to", "from", "with", "by", "as", "if",
    "when", "while", "before", "after", "besides", "however", "therefore",
    "please", "our", "your", "their", "here", "there", "what", "why", "how",
    "where", "who", "understanding", "although", "because", "since", "unless",
    "until", "whether"
]

private func splitGluedBlockSeams(in line: String) -> [String] {
    let range = NSRange(location: 0, length: (line as NSString).length)
    let afterPunctuation = punctuatedBlockSeamRegex.stringByReplacingMatches(
        in: line, range: range, withTemplate: "$1\n")

    var outputLines: [String] = []
    for segment in afterPunctuation.components(separatedBy: "\n") {
        let nsSegment = segment as NSString
        let matches = gluedBlockWordSeamRegex.matches(
            in: segment, range: NSRange(location: 0, length: nsSegment.length))
        guard !matches.isEmpty else {
            outputLines.append(segment)
            continue
        }
        var rebuilt = ""
        var cursor = 0
        for match in matches {
            let fullToken = nsSegment.substring(with: match.range)
            let left = nsSegment.substring(with: match.range(at: 1))
            let right = nsSegment.substring(with: match.range(at: 2))
            let lowerFull = fullToken.lowercased()
            let shouldSplit: Bool
            if knownMixedCaseWords.contains(lowerFull) ||
               lowerFull.hasPrefix("mc") || lowerFull.hasPrefix("mac") ||
               lowerFull.hasPrefix("fitz") {
                shouldSplit = false
            } else if left.first?.isLowercase == true {
                let leftValid = validatedEnglishWord(left)?.caseInsensitiveCompare(left) == .orderedSame
                let rightValid = validatedEnglishWord(right)?.caseInsensitiveCompare(right) == .orderedSame ||
                    paragraphStarterWords.contains(right.lowercased())
                shouldSplit = leftValid && rightValid
            } else {
                let leftValid = validatedEnglishWord(left) != nil
                shouldSplit = leftValid && paragraphStarterWords.contains(right.lowercased())
            }
            if shouldSplit {
                let splitPoint = match.range(at: 1).location + match.range(at: 1).length
                rebuilt += nsSegment.substring(with: NSRange(location: cursor, length: splitPoint - cursor))
                rebuilt += "\n"
                cursor = splitPoint
            }
        }
        rebuilt += nsSegment.substring(from: cursor)
        outputLines.append(contentsOf: rebuilt.components(separatedBy: "\n"))
    }
    return outputLines
}

func normalizeSourceSelectionParagraphs(_ raw: String) -> String {
    let cleaned = raw
        .replacingOccurrences(of: "\u{FFFC}", with: "")
        .replacingOccurrences(of: "\u{00A0}", with: " ")
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return "" }

    let bulletChars = CharacterSet(charactersIn: "•◦▪")
    var paragraphs: [String] = []
    for rawLine in cleaned.components(separatedBy: "\n") {
        for seamSplitLine in splitGluedBlockSeams(in: rawLine) {
            let line = seamSplitLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // Split inline bullet markers (e.g. "...services• What we expect...")
            let parts = line.components(separatedBy: bulletChars)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if parts.count >= 2, line.unicodeScalars.contains(where: { bulletChars.contains($0) }) {
                let startsWithBullet = line.unicodeScalars.first.map { bulletChars.contains($0) } ?? false
                let restHavePeriods = parts.dropFirst().allSatisfy { $0.hasSuffix(".") }
                for (index, part) in parts.enumerated() {
                    if index == 0 && !startsWithBullet &&
                       (part.hasSuffix(":") || (part.hasSuffix(".") && !restHavePeriods)) {
                        paragraphs.append(part)
                    } else {
                        paragraphs.append("• \(part)")
                    }
                }
            } else {
                paragraphs.append(line)
            }
        }
    }
    return paragraphs.joined(separator: "\n")
}

func eligibleEnglishText(_ raw: String, maxLength: Int) -> String? {
    let text = normalizeSourceSelectionParagraphs(raw)
    guard (2...maxLength).contains(text.count),
          text.range(of: "[A-Za-z]", options: .regularExpression) != nil else {
        return nil
    }
    let words = clipboardWords(text)
    if words.count < 4 {
        guard !looksLikePathOrCode(text),
              !text.contains("{") && !text.contains("}") else {
            return nil
        }
    } else {
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        let codeOrPathLines = lines.filter {
            looksLikePathOrCode($0) || $0.contains("{") || $0.contains("}")
        }
        if codeOrPathLines.count == lines.count, words.count < 8 {
            return nil
        }
    }
    if text.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) {
        // English prose may quote Chinese examples. Keep its full selection,
        // while a Chinese passage with a stray Latin abbreviation stays out.
        guard words.count >= 3,
              englishDominant(text) else { return nil }
    }
    if words.count >= 3 {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if (recognizer.languageHypotheses(withMaximum: 3)[.english] ?? 0) < 0.35 {
            return nil
        }
    }
    return text
}

func eligibleClipboardHint(_ raw: String) -> String? {
    eligibleEnglishText(raw, maxLength: 400)
}

func formatSelectionTranslation(_ text: String, source: String? = nil) -> String {
    var raw = text
        .replacingOccurrences(of: "\u{FFFC}", with: "")
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !raw.isEmpty else { return "" }

    // Strip outer matched quotation marks if the model quoted the full translation
    if (raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2) ||
       (raw.hasPrefix("“") && raw.hasSuffix("”") && raw.count >= 2) {
        raw = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let sourceBulletCount = source.map { src in
        src.components(separatedBy: "\n").filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("•") || t.hasPrefix("◦") || t.hasPrefix("▪")
        }.count
    } ?? 0

    let bulletChars = CharacterSet(charactersIn: "•◦▪")
    var paragraphs: [String] = []

    for rawLine in raw.components(separatedBy: "\n") {
        var current = rawLine.trimmingCharacters(in: .whitespaces)
        guard !current.isEmpty else { continue }

        if current.hasPrefix("#") {
            current = current.replacingOccurrences(of: #"^#+\s*"#, with: "",
                                                   options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        guard !current.isEmpty else { continue }

        // 1. Split inline bullet symbols (•, ◦, ▪) even when no spaces surround them
        let bulletParts = current.components(separatedBy: bulletChars)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if bulletParts.count >= 2 {
            let startsWithBullet = current.unicodeScalars.first.map { bulletChars.contains($0) } ?? false
            for (index, part) in bulletParts.enumerated() {
                if index == 0 && !startsWithBullet && (part.hasSuffix(":") || part.hasSuffix("：")) {
                    paragraphs.append(part)
                } else if index == 0 && !startsWithBullet && bulletParts.count == 2 && sourceBulletCount < 2 {
                    paragraphs.append(part)
                } else {
                    paragraphs.append("• \(part)")
                }
            }
            continue
        }

        // 2. Check for middle-dot (・ U+30FB or · U+00B7) collapsed clause lists
        var splitByMiddleDot = false
        for dot in ["・", "·"] where current.contains(dot) {
            let parts = current.components(separatedBy: dot)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            // Foreign names (e.g. 莱昂纳多·达·芬奇) have short name segments without clause punctuation.
            // List clauses have length >= 6 across all items and at least one longer or punctuated clause.
            let isClauseList = parts.count >= 2 &&
                parts.allSatisfy { $0.count >= 6 } &&
                parts.contains {
                    $0.count >= 10 || $0.contains("，") || $0.contains("。") ||
                        $0.contains("；") || $0.contains("——")
                }
            if isClauseList {
                for part in parts {
                    if part.hasPrefix("•") || part.hasPrefix("-") {
                        paragraphs.append(part)
                    } else {
                        paragraphs.append("• \(part)")
                    }
                }
                splitByMiddleDot = true
                break
            }
        }
        if splitByMiddleDot { continue }

        // Ensure consistent "• " spacing if the line starts with "•" without a space
        if current.hasPrefix("•") && !current.hasPrefix("• ") {
            let rest = current.dropFirst().trimmingCharacters(in: .whitespaces)
            current = "• \(rest)"
        }
        paragraphs.append(current)
    }

    return paragraphs.joined(separator: "\n")
}

func oneMissingCharacter(_ complete: String, _ fragment: String) -> Bool {
    let letters = Array(complete)
    guard letters.count == fragment.count + 1 else { return false }
    return letters.indices.contains { index in
        var candidate = letters
        candidate.remove(at: index)
        return String(candidate) == fragment
    }
}

func hintSupportsFocus(_ hint: String, anchor: String) -> Bool {
    let targetWords = clipboardWords(anchor)
    return clipboardWords(hint).contains { word in
        guard word.count >= 2 else { return false }
        if targetWords.contains(word) { return true }
        // A complete copied word is not evidence for a different, shorter word.
        if validatedEnglishWord(word)?.caseInsensitiveCompare(word) == .orderedSame {
            return false
        }
        return targetWords.contains {
            $0.contains(word) || oneMissingCharacter($0, word)
        }
    }
}

func foldedLetters(_ text: String) -> [Character] {
    Array(text.lowercased().filter { $0.isASCII && $0.isLetter })
}

func oneEditCost(_ first: [Character], _ second: [Character]) -> Int? {
    let allowed = min(first.count, second.count) >= 5 ? 1 : 0
    guard abs(first.count - second.count) <= allowed else { return nil }
    var left = 0
    var right = 0
    var edits = 0
    while left < first.count && right < second.count {
        if first[left] == second[right] {
            left += 1
            right += 1
            continue
        }
        edits += 1
        if edits > allowed { return nil }
        if first.count >= second.count { left += 1 }
        if second.count >= first.count { right += 1 }
    }
    edits += (first.count - left) + (second.count - right)
    return edits <= allowed ? edits : nil
}

func selectedTextAtFocus(_ hint: String, anchor: String,
                                 focusLine: String, focusWordIndex: Int,
                                 allowShortOCRNoise: Bool = false,
                                 minimumVerifiedWords: Int = 2,
                                 minimumVerifiedLetters: Int = 0,
                                 windowRadius: Int = 2) -> String? {
    guard hint.count <= 4000 else { return nil }
    let selected = clipboardWords(hint).map(foldedLetters)
    let visible = clipboardWords(focusLine).map(foldedLetters)
    guard selected.count > 1, visible.indices.contains(focusWordIndex),
          !visible[focusWordIndex].isEmpty else { return nil }
    // The selected text is authoritative for an active selection. Vision may
    // join "Thanks again" into "Thanksagain" or misread one nearby letter.
    var selectedStarts = [Int]()
    var selectedEnd = 0
    for word in selected {
        selectedStarts.append(selectedEnd)
        selectedEnd += word.count
    }
    let source = selected.flatMap { $0 }
    let focus = visible[focusWordIndex]
    let firstRow = max(0, focusWordIndex - windowRadius)
    let lastRow = min(visible.count - 1, focusWordIndex + windowRadius)
    for first in selected.indices {
        for last in first..<min(selected.count, first + 4) {
            let start = selectedStarts[first]
            let end = selectedStarts[last] + selected[last].count
            guard let focusCost = oneEditCost(focus, Array(source[start..<end])) else {
                continue
            }
            var lower = start
            var upper = end
            var edits = focusCost
            var verifiedWords = 1
            var conflict = false
            for rowIndex in firstRow...lastRow where rowIndex != focusWordIndex {
                let rowWord = visible[rowIndex]
                let mappedStart: Int
                if rowIndex < focusWordIndex {
                    let distance = visible[rowIndex..<focusWordIndex]
                        .reduce(0) { $0 + $1.count }
                    mappedStart = start - distance
                } else {
                    let distance = visible[(focusWordIndex + 1)..<rowIndex]
                        .reduce(0) { $0 + $1.count }
                    mappedStart = end + distance
                }
                let mappedEnd = mappedStart + rowWord.count
                if mappedEnd <= 0 || mappedStart >= source.count { continue }
                guard mappedStart >= 0, mappedEnd <= source.count,
                      let cost = oneEditCost(rowWord,
                                             Array(source[mappedStart..<mappedEnd])) else {
                    // AX confirms an active selection. Vision often reads a
                    // selected "I" as "l" or clips the first letter of "No".
                    if allowShortOCRNoise && rowWord.count <= 2 { continue }
                    conflict = true
                    break
                }
                verifiedWords += 1
                edits += cost
                if edits > 1 {
                    conflict = true
                    break
                }
                lower = min(lower, mappedStart)
                upper = max(upper, mappedEnd)
            }
            if conflict { continue }
            let matchedWords = selected.indices.filter {
                selectedStarts[$0] >= lower &&
                    selectedStarts[$0] + selected[$0].count <= upper
            }.count
            if matchedWords >= minimumVerifiedWords,
               verifiedWords >= minimumVerifiedWords,
               upper - lower >= minimumVerifiedLetters {
                return hint
            }
        }
    }
    return nil
}

func selectionHighlightAtCenter(_ image: CGImage, focus: CGPoint,
                                        row: CGRect?) -> Bool {
    guard let row else { return false }
    let bitmap = NSBitmapImageRep(cgImage: image)
    let width = bitmap.pixelsWide
    let height = bitmap.pixelsHigh
    let x = Int(focus.x * CGFloat(width))
    let y = Int((1 - focus.y) * CGFloat(height))
    func colorDistance(_ a: Int, _ b: Int) -> Int {
        abs(((a >> 16) & 255) - ((b >> 16) & 255)) +
        abs(((a >> 8) & 255) - ((b >> 8) & 255)) +
        abs((a & 255) - (b & 255))
    }
    func chroma(_ color: Int) -> Int {
        let channels = [(color >> 16) & 255, (color >> 8) & 255, color & 255]
        return (channels.max() ?? 0) - (channels.min() ?? 0)
    }
    func dominant(_ x: Int, _ y: Int, radius: Int = 6) -> (Int, Int)? {
        guard x >= radius, y >= radius,
              x + radius < width, y + radius < height else { return nil }
        var counts: [Int: Int] = [:]
        for yy in (y - radius)...(y + radius) {
            for xx in (x - radius)...(x + radius) {
                guard let color = bitmap.colorAt(x: xx, y: yy)?
                    .usingColorSpace(.deviceRGB) else { continue }
                let red = Int(color.redComponent * 255 / 8) * 8
                let green = Int(color.greenComponent * 255 / 8) * 8
                let blue = Int(color.blueComponent * 255 / 8) * 8
                let key = (red << 16) | (green << 8) | blue
                counts[key, default: 0] += 1
            }
        }
        return counts.max(by: { $0.value < $1.value })
            .map { ($0.key, $0.value) }
    }
    let rowTop = max(0, Int((1 - row.maxY) * CGFloat(height)))
    let rowBottom = min(height - 1, Int((1 - row.minY) * CGFloat(height)))
    func tintedRowFill(_ cx: Int, _ cy: Int, radius: Int = 9) -> (Int, Int)? {
        let minX = max(0, cx - radius)
        let maxX = min(width - 1, cx + radius)
        let minY = max(rowTop, cy - radius)
        let maxY = min(rowBottom, cy + radius)
        guard minX <= maxX, minY <= maxY else { return nil }
        var counts: [Int: Int] = [:]
        for yy in minY...maxY {
            for xx in minX...maxX {
                guard let color = bitmap.colorAt(x: xx, y: yy)?
                    .usingColorSpace(.deviceRGB) else { continue }
                let r = Int(color.redComponent * 255 / 16) * 16
                let g = Int(color.greenComponent * 255 / 16) * 16
                let b = Int(color.blueComponent * 255 / 16) * 16
                let key = (r << 16) | (g << 8) | b
                if chroma(key) >= 24 {
                    counts[key, default: 0] += 1
                }
            }
        }
        return counts.max(by: { $0.value < $1.value })
            .map { ($0.key, $0.value) }
    }
    let centerColor: Int
    if let primary = dominant(x, y), primary.1 >= 25, chroma(primary.0) >= 25 {
        centerColor = primary.0
    } else if let tinted = tintedRowFill(x, y), tinted.1 >= 20, chroma(tinted.0) >= 24 {
        centerColor = tinted.0
    } else {
        return false
    }
    let left = Int(row.minX * CGFloat(width)) - 14
    let right = Int(row.maxX * CGFloat(width)) + 14
    let above = Int((1 - row.maxY) * CGFloat(height)) - 14
    let below = Int((1 - row.minY) * CGFloat(height)) + 14
    let references = [
        dominant(left, y), dominant(right, y),
        dominant(x, above), dominant(x, below),
        dominant(left - 36, y), dominant(right + 36, y),
        dominant(x, above - 48), dominant(x, below + 48),
        dominant(12, y), dominant(width - 13, y)
    ].compactMap { $0 }
    // A dark unselected row can differ greatly from the blue selection on
    // the row beside it. The center itself must carry the tinted fill.
    return chroma(centerColor) >= 24 && references.contains {
        colorDistance(centerColor, $0.0) >= 75 &&
            chroma(centerColor) - chroma($0.0) >= 15
    }
}

func visuallyConfirmedSelection(_ live: LiveSelection,
                                        passage: FocusedPassage?,
                                        image: CGImage, focus: CGPoint) -> Bool {
    guard live.text != nil, let passage else { return false }
    return selectionHighlightAtCenter(image, focus: focus,
                                      row: passage.selectionFocusRowBox)
}

func hintedOCRCorrection(_ raw: String, hint: String?) -> String? {
    guard let hint else { return nil }
    let rawLower = raw.lowercased().replacingOccurrences(of: "’", with: "'")
    let candidates = clipboardWords(hint).filter {
        oneMissingCharacter($0, rawLower) && validatedEnglishWord($0) != nil
    }
    return candidates.count == 1 ? candidates[0] : nil
}

func focusedWordWithHint(_ raw: String, hint: String?) ->
    (word: String?, usedHint: Bool) {
    let ordinary = validatedEnglishWord(raw)
    if ordinary?.caseInsensitiveCompare(raw) != .orderedSame,
       let hinted = hintedOCRCorrection(raw, hint: hint) {
        return (hinted, true)
    }
    // Vision already located a Latin token under the gaze. Spell checking may
    // reject names, inflections, or noisy OCR; keep that token as a low-confidence
    // focus instead of silently switching to a neighboring word.
    return (ordinary ?? (raw.count >= 2 ? raw : nil), false)
}

// Eye-shaped, click-through word translation experiment. The clear center is live desktop content.
// ⌃⌥L toggles the lens; Esc hides it. Optional: --fixed-point <x> <y> (AppKit coordinates).
import AppKit
import Carbon.HIToolbox
import Darwin
import ImageIO
import NaturalLanguage
import ScreenCaptureKit
import SwiftUI
import Translation
import Vision

private func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
private func ms(_ start: Double) -> Double { (uptime() - start) * 1_000 }

private struct FocusedPassage {
    let anchor: String
    let sentence: String
    let focusLine: String
    let focusWordIndex: Int
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

private let focusMarker = "⟦X⟧"
private let relativeTimeRegex = try! NSRegularExpression(
    pattern: "\\b([0-9]+)?\\s*(seconds?|minutes?|hours?|days?|weeks?|months?|years?)\\s*ago\\b",
    options: [.caseInsensitive])
private let englishIslandRegex = try! NSRegularExpression(
    pattern: "[A-Za-z]+(?:['’][A-Za-z]+)?(?:\\s+[A-Za-z]+(?:['’][A-Za-z]+)?)*")

private func relativeTimeChinese(_ source: String) -> String? {
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

private func cleanChineseTerm(_ text: String) -> String? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let scalars = Array(value.unicodeScalars)
    guard (1...8).contains(scalars.count), scalars.allSatisfy({
        (0x3400...0x9FFF).contains($0.value)
    }) else { return nil }
    return value
}

private func translatedDifference(_ translated: String, _ masked: String,
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

private func focusedChineseWord(full: String, masked: String,
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

private func sharedContextTerm(full: String, local: String, maskedLocal: String,
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

private func dictionaryTerm(_ direct: String?) -> String? {
    guard let direct else { return nil }
    if let clean = cleanChineseTerm(direct) { return clean }
    // Apple's standalone gloss can be a template such as “在...以前”.
    let parts = direct.replacingOccurrences(of: "……", with: "...")
        .replacingOccurrences(of: "…", with: "...")
        .components(separatedBy: "...")
    guard parts.count > 1 else { return nil }
    return parts.reversed().compactMap(cleanChineseTerm).first
}

private func resolveFocus(anchor: String, full: String, masked: String,
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
       word.count >= 2 || full.contains(word) || local.contains(word) {
        return FocusedTranslation(chinese: word, basis: "邻近短语")
    }
    if let word = translatedDifference(prefix, maskedPrefix,
                                       allowOneCharacterSuffix: true),
       !maskedPrefix.contains(word),
       word.count >= 2 || full.contains(word) || local.contains(word) {
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
    // Contextual alignment can fail even when OCR has located the right word.
    // A marked dictionary-like answer is more useful than a silent miss here.
    // Very short words are excluded because standalone Translation commonly
    // treats "in" as the chemical element rather than the preposition.
    if normalized.count >= 3, let word = dictionaryTerm(direct) {
        return FocusedTranslation(chinese: word, basis: "单词参考")
    }
    return FocusedTranslation(chinese: nil, basis: "")
}

private let proseCommentPrefix = try! NSRegularExpression(
    pattern: "^\\s*(?://+|#|/\\*+|\\*+)\\s*")
private let proseCommentWords = try! NSRegularExpression(pattern: "[A-Za-z]+(?:['’][A-Za-z]+)?")

private func proseCommentBodyRange(_ line: String) -> NSRange? {
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

private func looksLikePathOrCode(_ line: String) -> Bool {
    if proseCommentBodyRange(line) != nil { return false }
    if line.contains("/") || line.contains("\\") || line.contains("://") { return true }
    let lower = line.lowercased()
    return [".app", ".swift", ".mjs", ".js", ".json", ".py", ".md"].contains {
        lower.contains($0)
    }
}

private func validatedEnglishWord(_ raw: String) -> String? {
    let word = raw.replacingOccurrences(of: "’", with: "'")
    guard word.range(of: "^(?:[A-Za-z]{2,24}|[AaIi]|[A-Za-z]{2,20}'[A-Za-z]{1,5})$",
                     options: .regularExpression) != nil else { return nil }
    if word.count <= 2 {
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

private let clipboardWordRegex = try! NSRegularExpression(
    pattern: "[A-Za-z]+(?:['’][A-Za-z]+)?")

private func clipboardWords(_ text: String) -> [String] {
    let source = text as NSString
    return clipboardWordRegex.matches(in: text,
                                      range: NSRange(location: 0, length: source.length)).map {
        source.substring(with: $0.range).lowercased()
            .replacingOccurrences(of: "’", with: "'")
    }
}

private func eligibleClipboardHint(_ raw: String) -> String? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (2...400).contains(text.count),
          text.range(of: "[A-Za-z]", options: .regularExpression) != nil,
          !text.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }),
          !looksLikePathOrCode(text), !text.contains("{") && !text.contains("}") else {
        return nil
    }
    if clipboardWords(text).count >= 3 {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if (recognizer.languageHypotheses(withMaximum: 3)[.english] ?? 0) < 0.35 {
            return nil
        }
    }
    return text
}

private func oneMissingCharacter(_ complete: String, _ fragment: String) -> Bool {
    let letters = Array(complete)
    guard letters.count == fragment.count + 1 else { return false }
    return letters.indices.contains { index in
        var candidate = letters
        candidate.remove(at: index)
        return String(candidate) == fragment
    }
}

private func hintSupportsFocus(_ hint: String, anchor: String) -> Bool {
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

private func selectedTextAtFocus(_ hint: String, anchor: String,
                                 focusLine: String, focusWordIndex: Int) -> String? {
    guard hint.count <= 200 else { return nil }
    let selected = clipboardWords(hint)
    var visible = clipboardWords(focusLine)
    let focus = clipboardWords(anchor)
    guard focus.count == 1, selected.contains(focus[0]),
          visible.indices.contains(focusWordIndex) else {
        return nil
    }
    let rawFocus = visible[focusWordIndex]
    guard rawFocus == focus[0] || oneMissingCharacter(focus[0], rawFocus) else {
        return nil
    }
    visible[focusWordIndex] = focus[0]
    // One copied word keeps the contextual focal translation. A fragment such as
    // “ne” remains OCR evidence for “one”, never an independent translation.
    guard selected.count > 1 else { return nil }
    // OCR far from the focus can be noisy (emoji and selected text are common).
    // Compare the focus and up to two words on each side on this exact row.
    // The third word still disambiguates nearby "before the ..." lines.
    for selectedIndex in selected.indices where selected[selectedIndex] == focus[0] {
        var matched = 0
        var conflict = false
        let local = max(0, selectedIndex - 2)...min(selected.count - 1,
                                                    selectedIndex + 2)
        for index in local {
            let rowIndex = focusWordIndex + index - selectedIndex
            guard visible.indices.contains(rowIndex) else { continue }
            if selected[index] != visible[rowIndex] {
                conflict = true
                break
            }
            matched += 1
        }
        if !conflict && matched >= 2 { return hint }
    }
    return nil
}

private func hintedOCRCorrection(_ raw: String, hint: String?) -> String? {
    guard let hint else { return nil }
    let rawLower = raw.lowercased().replacingOccurrences(of: "’", with: "'")
    let candidates = clipboardWords(hint).filter {
        oneMissingCharacter($0, rawLower) && validatedEnglishWord($0) != nil
    }
    return candidates.count == 1 ? candidates[0] : nil
}

private func focusedWordWithHint(_ raw: String, hint: String?) ->
    (word: String?, usedHint: Bool) {
    let ordinary = validatedEnglishWord(raw)
    guard ordinary?.caseInsensitiveCompare(raw) != .orderedSame,
          let hinted = hintedOCRCorrection(raw, hint: hint) else {
        return (ordinary, false)
    }
    return (hinted, true)
}

private func passageAtCenter(_ image: CGImage, focus: CGPoint,
                             debug: Bool = false,
                             accurate: Bool = false,
                             clipboardHint: String? = nil) throws -> (FocusedPassage?, Double) {
    let start = uptime()
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = accurate ? .accurate : .fast
    request.recognitionLanguages = ["en-US", "zh-Hans"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    let regex = try NSRegularExpression(pattern: "[A-Za-z]+(?:['’][A-Za-z]+)?")
    // A multiword copy can overlap several nearby lines. It must not bias
    // geometric word choice or repair OCR before the actual focus row is known.
    let focalWordHint = clipboardHint.flatMap {
        clipboardWords($0).count == 1 ? $0 : nil
    }

    struct Piece {
        let text: String
        let candidate: VNRecognizedText
        let box: CGRect
        let start: Int // UTF-16 offset in its assembled row.
    }
    struct Row {
        var text = ""
        var parts: [Piece] = []
        var box = CGRect.null
    }
    let raw = (request.results ?? []).compactMap { observation -> Piece? in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        return Piece(text: candidate.string, candidate: candidate,
                     box: observation.boundingBox, start: 0)
    }.sorted {
        if abs($0.box.midY - $1.box.midY) < min($0.box.height, $1.box.height) * 0.35 {
            return $0.box.minX < $1.box.minX
        }
        return $0.box.midY > $1.box.midY
    }
    if debug {
        for piece in raw {
            print("OCR_PIECE box=\(piece.box) confidence=\(piece.candidate.confidence) text=\(piece.text)")
        }
    }
    // Vision sometimes splits one visual line or one word into observations.
    // First recover horizontal rows, then tokenize their combined text.
    var bands: [[Piece]] = []
    for piece in raw {
        if let index = bands.firstIndex(where: { band in
            abs(piece.box.midY - band[0].box.midY) <=
                min(piece.box.height, band[0].box.height) * 0.42
        }) {
            bands[index].append(piece)
        } else {
            bands.append([piece])
        }
    }
    var rows: [Row] = []
    func isLatin(_ character: Character?) -> Bool {
        guard let character, character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else { return false }
        return (65...90).contains(value) || (97...122).contains(value)
    }
    func edgeWord(_ text: String, first: Bool) -> String? {
        let matches = regex.matches(in: text,
                                    range: NSRange(location: 0, length: (text as NSString).length))
        guard let match = first ? matches.first : matches.last else { return nil }
        return (text as NSString).substring(with: match.range)
    }
    for band in bands {
        var row = Row()
        for piece in band.sorted(by: { $0.box.minX < $1.box.minX }) {
            if let previous = row.parts.last {
                let gapPixels = (piece.box.minX - previous.box.maxX) * CGFloat(image.width)
                let heightPixels = min(piece.box.height, previous.box.height) *
                    CGFloat(image.height)
                if gapPixels > max(heightPixels * 1.8, 8) {
                    rows.append(row)
                    row = Row()
                }
            }
            if let previous = row.parts.last {
                let gapPixels = (piece.box.minX - previous.box.maxX) * CGFloat(image.width)
                let heightPixels = min(piece.box.height, previous.box.height) *
                    CGFloat(image.height)
                let separateWords = edgeWord(previous.text, first: false).flatMap { left in
                    edgeWord(piece.text, first: true).map { right in
                        validatedEnglishWord(left) == left &&
                            validatedEnglishWord(right) == right
                    }
                } ?? false
                let joinsWord = gapPixels <= heightPixels * 0.22 && !separateWords &&
                    isLatin(previous.text.last) && isLatin(piece.text.first) &&
                    !(previous.text.last?.isLowercase == true &&
                      piece.text.first?.isUppercase == true)
                if !joinsWord { row.text += " " }
            }
            let offset = (row.text as NSString).length
            row.text += piece.text
            row.parts.append(Piece(text: piece.text, candidate: piece.candidate,
                                   box: piece.box, start: offset))
            row.box = row.box.isNull ? piece.box : row.box.union(piece.box)
        }
        if !row.parts.isEmpty { rows.append(row) }
    }
    if debug {
        for row in rows { print("OCR_ROW box=\(row.box) text=\(row.text)") }
    }
    let pathRows = rows.filter { looksLikePathOrCode($0.text) }.map { $0.box.midY }
    var found: [(row: Int, anchor: String, range: NSRange,
                 distance: CGFloat, centerDistance: CGFloat,
                 literalTranslation: String?, hinted: Bool)] = []
    for (rowIndex, row) in rows.enumerated() {
        guard !pathRows.contains(where: { abs($0 - row.box.midY) < 0.04 }),
              !looksLikePathOrCode(row.text) else { continue }
        let rowRange = NSRange(location: 0, length: (row.text as NSString).length)
        let timeMatches = relativeTimeRegex.matches(in: row.text, range: rowRange)
        func wordBox(for range: NSRange) -> CGRect {
            var wordBox = CGRect.null
            for piece in row.parts {
                let span = NSRange(location: piece.start,
                                   length: (piece.text as NSString).length)
                let overlap = NSIntersectionRange(range, span)
                guard overlap.length > 0,
                      let local = Range(NSRange(location: overlap.location - piece.start,
                                                length: overlap.length), in: piece.text),
                      let recognized = try? piece.candidate.boundingBox(for: local) else { continue }
                wordBox = wordBox.isNull ? recognized.boundingBox :
                    wordBox.union(recognized.boundingBox)
            }
            return wordBox
        }
        for match in timeMatches {
            let source = (row.text as NSString).substring(with: match.range)
            guard let translation = relativeTimeChinese(source) else { continue }
            let count = match.range(at: 1).location == NSNotFound ? "" :
                (row.text as NSString).substring(with: match.range(at: 1))
            let unit = (row.text as NSString).substring(with: match.range(at: 2)).lowercased()
            let displayAnchor = count.isEmpty ? "\(unit) ago" : "\(count) \(unit) ago"
            let box = wordBox(for: match.range)
            guard !box.isNull else { continue }
            let dx = max(box.minX - focus.x, 0, focus.x - box.maxX)
            let dy = max(box.minY - focus.y, 0, focus.y - box.maxY)
            let distance = hypot(dx / 0.04, dy / 0.055)
            guard distance <= 1 else { continue }
            let centerDistance = hypot((box.midX - focus.x) / 0.04,
                                       (box.midY - focus.y) / 0.055)
            found.append((rowIndex, displayAnchor, match.range, distance,
                          centerDistance, translation,
                          focalWordHint.map { hintSupportsFocus($0, anchor: displayAnchor) } ?? false))
        }
        let matches = regex.matches(in: row.text, range: rowRange)
        for match in matches {
            guard !timeMatches.contains(where: {
                NSIntersectionRange(match.range, $0.range).length > 0
            }) else { continue }
            let rawWord = (row.text as NSString).substring(with: match.range)
            let wordBox = wordBox(for: match.range)
            guard !wordBox.isNull else { continue }
            let dx = max(wordBox.minX - focus.x, 0, focus.x - wordBox.maxX)
            let dy = max(wordBox.minY - focus.y, 0, focus.y - wordBox.maxY)
            let distance = hypot(dx / 0.04, dy / 0.055)
            if debug {
                print("OCR_WORD text=\(rawWord) box=\(wordBox) distance=\(distance) valid=\(validatedEnglishWord(rawWord) ?? "no")")
            }
            guard distance <= 1 else { continue }
            if rawWord.count <= 2 && distance > 0.25 { continue }
            guard let anchor = focusedWordWithHint(rawWord, hint: focalWordHint).word else {
                continue
            }
            let centerDistance = hypot((wordBox.midX - focus.x) / 0.04,
                                       (wordBox.midY - focus.y) / 0.055)
            found.append((rowIndex, anchor, match.range, distance, centerDistance,
                          nil, focalWordHint.map { hintSupportsFocus($0, anchor: anchor) } ?? false))
        }
    }
    guard let focused = found.min(by: {
        if $0.distance == 0 && $1.distance == 0 && $0.hinted != $1.hinted {
            return $0.hinted
        }
        return $0.distance == $1.distance ?
            $0.centerDistance < $1.centerDistance : $0.distance < $1.distance
    }),
          focused.distance <= 1 else { return (nil, ms(start)) }
    let focusedLine = rows[focused.row].text
    let focusWordIndex: Int
    if focused.distance <= 0.05 {
        focusWordIndex = regex.matches(
            in: focusedLine,
            range: NSRange(location: 0, length: (focusedLine as NSString).length)
        ).firstIndex(where: { NSIntersectionRange($0.range, focused.range).length > 0 }) ?? -1
    } else {
        // The normal word lens accepts near misses; selection promotion needs
        // a direct geometric hit so a neighboring compact row cannot win.
        focusWordIndex = -1
    }

    if let literal = focused.literalTranslation {
        let masked = (focused.anchor as NSString).replacingCharacters(
            in: NSRange(location: 0, length: (focused.anchor as NSString).length),
            with: focusMarker)
        return (FocusedPassage(anchor: focused.anchor, sentence: focused.anchor,
                               focusLine: focusedLine, focusWordIndex: focusWordIndex,
                               maskedSentence: masked, localContext: focused.anchor,
                               maskedLocalContext: masked, microContext: focused.anchor,
                               maskedMicroContext: masked, prefixContext: focused.anchor,
                               maskedPrefixContext: masked,
                               literalTranslation: literal, distance: focused.distance), ms(start))
    }

    // The gaze point identifies a word. A few tightly adjacent OCR rows supply
    // its source sentence; unrelated UI labels above or beside it stay out.
    let focusedRow = rows[focused.row]
    let ordinaryEnglish = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .,;:!?'-’")
    let mixedOrNoisy = focusedRow.text.unicodeScalars.contains {
        !ordinaryEnglish.contains($0)
    }
    let englishIsland = mixedOrNoisy ? englishIslandRegex.matches(
        in: focusedRow.text,
        range: NSRange(location: 0, length: (focusedRow.text as NSString).length)
    ).first(where: { NSIntersectionRange($0.range, focused.range).length > 0 }) : nil
    var selected = [focused.row]
    func canJoin(_ first: Int, _ second: Int) -> Bool {
        let a = rows[first].box
        let b = rows[second].box
        guard !looksLikePathOrCode(rows[second].text),
              !rows[second].text.unicodeScalars.contains(where: {
                  (0x3400...0x9FFF).contains($0.value)
              }), a.height > 0, b.height > 0 else { return false }
        let heightRatio = b.height / a.height
        let verticalGap = max(0, a.minY - b.maxY, b.minY - a.maxY)
        return (0.72...1.38).contains(heightRatio) &&
            verticalGap <= max(a.height, b.height) * 1.1 &&
            abs(a.minX - b.minX) <= 0.11 &&
            min(a.maxX, b.maxX) - max(a.minX, b.minX) > 0
    }
    var cursor = focused.row
    while cursor > 0 && selected.count < 4 && canJoin(cursor - 1, cursor) {
        selected.insert(cursor - 1, at: 0)
        cursor -= 1
    }
    cursor = focused.row
    while cursor + 1 < rows.count && selected.count < 4 && canJoin(cursor, cursor + 1) {
        selected.append(cursor + 1)
        cursor += 1
    }
    var combined = ""
    var anchorOffset = 0
    if let comment = proseCommentBodyRange(focusedRow.text),
       NSIntersectionRange(comment, focused.range).length > 0 {
        combined = (focusedRow.text as NSString).substring(with: comment)
        anchorOffset = focused.range.location - comment.location
    } else if let englishIsland {
        combined = (focusedRow.text as NSString).substring(with: englishIsland.range)
        anchorOffset = focused.range.location - englishIsland.range.location
    } else {
        for index in selected {
            if !combined.isEmpty { combined += " " }
            if index == focused.row {
                anchorOffset = (combined as NSString).length + focused.range.location
            }
            combined += rows[index].text
        }
    }
    let characters = Array(combined)
    let prefix = (combined as NSString).substring(to: min(anchorOffset,
                                                           (combined as NSString).length))
    let anchorCharacter = Array(prefix).count
    let breaks: Set<Character> = [".", "?", "!", "。", "？", "！"]
    let before = characters[..<min(anchorCharacter, characters.count)].lastIndex {
        breaks.contains($0)
    }
    let after = characters[min(anchorCharacter, characters.count)...].firstIndex {
        breaks.contains($0)
    }
    let lower = before.map { $0 + 1 } ?? 0
    var upper = after.map { $0 + 1 } ?? characters.count
    guard lower < upper else { return (nil, ms(start)) }
    var sentence = String(characters[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
    var words = regex.matches(in: sentence,
                              range: NSRange(location: 0, length: (sentence as NSString).length))
    if words.count < 3, upper < characters.count {
        let following = characters[upper...].firstIndex { breaks.contains($0) }
        upper = following.map { $0 + 1 } ?? characters.count
        sentence = String(characters[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
        words = regex.matches(in: sentence,
                              range: NSRange(location: 0, length: (sentence as NSString).length))
    }
    let sentencePrefix = String(characters[..<lower])
    let rawSentence = String(characters[lower..<upper])
    let leadingWhitespace = String(rawSentence.prefix(while: { $0.isWhitespace }))
    var offset = anchorOffset - (sentencePrefix as NSString).length -
        (leadingWhitespace as NSString).length
    guard offset >= 0, offset + focused.range.length <= (sentence as NSString).length else {
        return (nil, ms(start))
    }
    // A short UI label is not a language sample. Keep the contiguous, verified
    // words around the gaze and discard OCR debris such as "Upsr" after "Free plan".
    let compactLabel = words.count <= 5 && sentence.count <= 80 &&
        sentence.rangeOfCharacter(from: CharacterSet(charactersIn: ".?!")) == nil
    if compactLabel, let focusIndex = words.firstIndex(where: {
        $0.range.location <= offset && offset < NSMaxRange($0.range)
    }) {
        let source = sentence as NSString
        func trustedContextWord(_ index: Int) -> Bool {
            let raw = source.substring(with: words[index].range)
            guard let validated = validatedEnglishWord(raw) else { return false }
            return index == focusIndex || validated.caseInsensitiveCompare(raw) == .orderedSame
        }
        var first = focusIndex
        var last = focusIndex
        while first > 0 && trustedContextWord(first - 1) { first -= 1 }
        while last + 1 < words.count && trustedContextWord(last + 1) { last += 1 }
        if first > 0 || last + 1 < words.count {
            let selected = NSRange(location: words[first].range.location,
                                   length: NSMaxRange(words[last].range) -
                                       words[first].range.location)
            sentence = source.substring(with: selected)
            offset -= selected.location
            words = regex.matches(in: sentence,
                                  range: NSRange(location: 0,
                                                 length: (sentence as NSString).length))
        }
    }
    guard (1...60).contains(words.count), sentence.count <= 320,
          !looksLikePathOrCode(sentence),
          !sentence.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) else {
        return (nil, ms(start))
    }
    if debug && words.count >= 3 && !compactLabel {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sentence)
        let probabilities = recognizer.languageHypotheses(withMaximum: 3)
        let english = probabilities[.english] ?? 0
        print("OCR_LANGUAGE english=\(english) top=\(probabilities.values.max() ?? 0)")
    }
    // Keep the focal word and every translation context in sync after OCR repair.
    // Previously the card could show corrected "earth" while its context still
    // translated raw "earch", producing a convincing but unrelated Chinese term.
    guard let rawIndex = words.firstIndex(where: {
        $0.range.location <= offset && offset < NSMaxRange($0.range)
    }) else { return (nil, ms(start)) }
    let rawRange = words[rawIndex].range
    let rawFocused = (sentence as NSString).substring(with: rawRange)
    if rawFocused != focused.anchor {
        sentence = (sentence as NSString).replacingCharacters(
            in: rawRange, with: focused.anchor)
        words = regex.matches(in: sentence,
                              range: NSRange(location: 0,
                                             length: (sentence as NSString).length))
    }
    guard let focusedIndex = words.firstIndex(where: {
        $0.range.location <= rawRange.location && rawRange.location < NSMaxRange($0.range)
    }) else { return (nil, ms(start)) }
    let focusRange = words[focusedIndex].range
    let masked = (sentence as NSString).replacingCharacters(
        in: focusRange, with: focusMarker)
    let source = sentence as NSString
    let punctuation = CharacterSet(charactersIn: ",;:.?!，；：。？！")
    func crossesPunctuation(_ first: NSTextCheckingResult,
                            _ second: NSTextCheckingResult) -> Bool {
        let gap = NSRange(location: NSMaxRange(first.range),
                          length: second.range.location - NSMaxRange(first.range))
        return source.substring(with: gap).rangeOfCharacter(from: punctuation) != nil
    }
    var leftIndex = focusedIndex
    var rightIndex = focusedIndex
    for _ in 0..<2 where leftIndex > 0 {
        guard !crossesPunctuation(words[leftIndex - 1], words[leftIndex]) else { break }
        leftIndex -= 1
    }
    for _ in 0..<3 where rightIndex + 1 < words.count {
        guard !crossesPunctuation(words[rightIndex], words[rightIndex + 1]) else { break }
        rightIndex += 1
    }
    let localRange = NSRange(location: words[leftIndex].range.location,
                             length: NSMaxRange(words[rightIndex].range) -
                                 words[leftIndex].range.location)
    let local = source.substring(with: localRange)
    let maskedLocal = (local as NSString).replacingCharacters(
        in: NSRange(location: focusRange.location - localRange.location,
                    length: focusRange.length), with: focusMarker)
    var microLeft = focusedIndex
    var microRight = focusedIndex
    for _ in 0..<2 where microRight + 1 < words.count {
        guard !crossesPunctuation(words[microRight], words[microRight + 1]) else { break }
        microRight += 1
    }
    if microRight == focusedIndex {
        for _ in 0..<2 where microLeft > 0 {
            guard !crossesPunctuation(words[microLeft - 1], words[microLeft]) else { break }
            microLeft -= 1
        }
    }
    let microRange = NSRange(location: words[microLeft].range.location,
                             length: NSMaxRange(words[microRight].range) -
                                 words[microLeft].range.location)
    let micro = source.substring(with: microRange)
    let maskedMicro = (micro as NSString).replacingCharacters(
        in: NSRange(location: focusRange.location - microRange.location,
                    length: focusRange.length), with: focusMarker)
    var prefixLeft = focusedIndex
    var prefixRight = focusedIndex
    if focusedIndex > 0,
       !crossesPunctuation(words[focusedIndex - 1], words[focusedIndex]) {
        prefixLeft -= 1
    } else if focusedIndex + 1 < words.count,
              !crossesPunctuation(words[focusedIndex], words[focusedIndex + 1]) {
        prefixRight += 1
    }
    let prefixRange = NSRange(location: words[prefixLeft].range.location,
                              length: NSMaxRange(words[prefixRight].range) -
                                  words[prefixLeft].range.location)
    let prefixContext = source.substring(with: prefixRange)
    let maskedPrefix = (prefixContext as NSString).replacingCharacters(
        in: NSRange(location: focusRange.location - prefixRange.location,
                    length: focusRange.length), with: focusMarker)
    return (FocusedPassage(anchor: focused.anchor, sentence: sentence,
                           focusLine: focusedLine, focusWordIndex: focusWordIndex,
                           maskedSentence: masked, localContext: local,
                           maskedLocalContext: maskedLocal,
                           microContext: micro, maskedMicroContext: maskedMicro,
                           prefixContext: prefixContext,
                           maskedPrefixContext: maskedPrefix,
                           literalTranslation: nil,
                           distance: focused.distance), ms(start))
}

@MainActor
private final class WordTranslationBridge: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    var pendingAnchor = ""
    var pendingSentence = ""
    var pendingMaskedSentence = ""
    var pendingLocalContext = ""
    var pendingMaskedLocalContext = ""
    var pendingMicroContext = ""
    var pendingMaskedMicroContext = ""
    var pendingPrefixContext = ""
    var pendingMaskedPrefixContext = ""
    var generation = -1
    var onResult: ((Int, Result<(FocusedTranslation, Double), Error>) -> Void)?

    func translate(anchor: String, sentence: String, maskedSentence: String,
                   localContext: String, maskedLocalContext: String,
                   microContext: String, maskedMicroContext: String,
                   prefixContext: String, maskedPrefixContext: String,
                   generation: Int) {
        pendingAnchor = anchor
        pendingSentence = sentence
        pendingMaskedSentence = maskedSentence
        pendingLocalContext = localContext
        pendingMaskedLocalContext = maskedLocalContext
        pendingMicroContext = microContext
        pendingMaskedMicroContext = maskedMicroContext
        pendingPrefixContext = prefixContext
        pendingMaskedPrefixContext = maskedPrefixContext
        self.generation = generation
        var next = configuration ?? .init(source: Locale.Language(identifier: "en"),
                                          target: Locale.Language(identifier: "zh-Hans"))
        next.invalidate()
        configuration = next
    }
}

private struct FocusedTranslation {
    let chinese: String?
    let basis: String
}

@MainActor
private final class SelectionTranslationBridge: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    var source = ""
    var requestID = 0
    var onResult: ((Int, Result<(String, Double), Error>) -> Void)?

    func translate(_ text: String, requestID: Int) {
        source = text
        self.requestID = requestID
        var next = configuration ?? .init(source: Locale.Language(identifier: "en"),
                                          target: Locale.Language(identifier: "zh-Hans"))
        next.invalidate()
        configuration = next
    }
}

@MainActor
private struct SelectionTranslationTaskView: View {
    @ObservedObject var bridge: SelectionTranslationBridge
    var body: some View {
        Color.clear.translationTask(bridge.configuration) { session in
            let source = bridge.source
            let requestID = bridge.requestID
            guard !source.isEmpty else { return }
            do {
                let start = uptime()
                let requests = [TranslationSession.Request(sourceText: source,
                                                           clientIdentifier: "selection")]
                let result = try await session.translations(from: requests)
                bridge.onResult?(requestID, .success((result.first?.targetText ?? "", ms(start))))
            } catch {
                bridge.onResult?(requestID, .failure(error))
            }
        }
    }
}

@MainActor
private struct TranslationTaskView: View {
    @ObservedObject var bridge: WordTranslationBridge
    var body: some View {
        Color.clear.translationTask(bridge.configuration) { session in
            let anchor = bridge.pendingAnchor
            let sentence = bridge.pendingSentence
            let maskedSentence = bridge.pendingMaskedSentence
            let localContext = bridge.pendingLocalContext
            let maskedLocalContext = bridge.pendingMaskedLocalContext
            let microContext = bridge.pendingMicroContext
            let maskedMicroContext = bridge.pendingMaskedMicroContext
            let prefixContext = bridge.pendingPrefixContext
            let maskedPrefixContext = bridge.pendingMaskedPrefixContext
            let generation = bridge.generation
            guard !anchor.isEmpty, !sentence.isEmpty, !maskedSentence.isEmpty,
                  !localContext.isEmpty, !maskedLocalContext.isEmpty,
                  !microContext.isEmpty, !maskedMicroContext.isEmpty,
                  !prefixContext.isEmpty, !maskedPrefixContext.isEmpty else { return }
            do {
                let start = uptime()
                let requests = [
                    TranslationSession.Request(sourceText: sentence,
                                               clientIdentifier: "context"),
                    TranslationSession.Request(sourceText: maskedSentence,
                                               clientIdentifier: "masked"),
                    TranslationSession.Request(sourceText: anchor,
                                               clientIdentifier: "word"),
                    TranslationSession.Request(sourceText: localContext,
                                               clientIdentifier: "local"),
                    TranslationSession.Request(sourceText: maskedLocalContext,
                                               clientIdentifier: "maskedLocal"),
                    TranslationSession.Request(sourceText: microContext,
                                               clientIdentifier: "micro"),
                    TranslationSession.Request(sourceText: maskedMicroContext,
                                               clientIdentifier: "maskedMicro"),
                    TranslationSession.Request(sourceText: prefixContext,
                                               clientIdentifier: "prefix"),
                    TranslationSession.Request(sourceText: maskedPrefixContext,
                                               clientIdentifier: "maskedPrefix")
                ]
                let responses = try await session.translations(from: requests)
                let translated = Dictionary(uniqueKeysWithValues: responses.compactMap {
                    response -> (String, String)? in
                    guard let id = response.clientIdentifier else { return nil }
                    return (id, response.targetText)
                })
                if ProcessInfo.processInfo.environment["EASYLENS_DEBUG_TRANSLATION"] == "1" {
                    for id in ["context", "masked", "word", "local", "maskedLocal",
                               "micro", "maskedMicro", "prefix", "maskedPrefix"] {
                        print("TRANSLATION_DEBUG \(id)=\(translated[id] ?? "<missing>")")
                    }
                    fflush(stdout)
                }
                let focus = resolveFocus(anchor: anchor,
                                         full: translated["context"] ?? "",
                                         masked: translated["masked"] ?? "",
                                         local: translated["local"] ?? "",
                                         maskedLocal: translated["maskedLocal"] ?? "",
                                         sourceLocal: localContext,
                                         sourceMicro: microContext,
                                         micro: translated["micro"] ?? "",
                                         maskedMicro: translated["maskedMicro"] ?? "",
                                         sourcePrefix: prefixContext,
                                         prefix: translated["prefix"] ?? "",
                                         maskedPrefix: translated["maskedPrefix"] ?? "",
                                         direct: translated["word"])
                bridge.onResult?(generation, .success((focus, ms(start))))
            } catch {
                bridge.onResult?(generation, .failure(error))
            }
        }
    }
}

@MainActor
private final class EyeLensView: NSView {
    var isReading = false { didSet { needsDisplay = true } }

    static func eyePath(in rect: CGRect) -> NSBezierPath {
        let left = CGPoint(x: rect.minX, y: rect.midY - 2)
        let right = CGPoint(x: rect.maxX, y: rect.midY + 2)
        let path = NSBezierPath()
        path.move(to: left)
        path.curve(to: right,
                   controlPoint1: CGPoint(x: rect.minX + rect.width * 0.23,
                                          y: rect.midY + rect.height * 0.65),
                   controlPoint2: CGPoint(x: rect.minX + rect.width * 0.73,
                                          y: rect.midY + rect.height * 0.65))
        path.curve(to: left,
                   controlPoint1: CGPoint(x: rect.minX + rect.width * 0.77,
                                          y: rect.midY - rect.height * 0.56),
                   controlPoint2: CGPoint(x: rect.minX + rect.width * 0.27,
                                          y: rect.midY - rect.height * 0.56))
        path.close()
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let eyeRect = bounds.insetBy(dx: 3, dy: 3)
        let eye = Self.eyePath(in: eyeRect)

        // The eyelids mask the round iris; all accents stay outside the clear pupil.
        let center = CGPoint(x: eyeRect.midX, y: eyeRect.midY)
        let irisRadiusX = eyeRect.height * 0.75
        let irisRadiusY = eyeRect.height * 0.50
        let iris = CGRect(x: center.x - irisRadiusX, y: center.y - irisRadiusY,
                          width: irisRadiusX * 2, height: irisRadiusY * 2)
        let pupil = iris.insetBy(dx: irisRadiusX * 0.20, dy: irisRadiusY * 0.20)
        context.saveGState()
        eye.addClip()
        context.addEllipse(in: iris)
        context.addEllipse(in: pupil)
        context.clip(using: .evenOdd)
        context.setLineCap(.round)
        for index in 0..<96 {
            let phase = CGFloat(index)
            let angle = (phase / 96) * 2 * CGFloat.pi + sin(phase * 2.11) * 0.027
            let innerFactor = 0.79 + 0.03 * sin(phase * 1.7)
            let outerFactor = 0.94 + 0.045 * sin(phase * 1.31)
            let middleFactor = (innerFactor + outerFactor) / 2
            let bend = angle + 0.06 * sin(phase * 0.83)
            let hue = index.isMultiple(of: 4)
                ? NSColor(calibratedRed: 0.30, green: 0.72, blue: 0.96, alpha: 0.15)
                : NSColor(calibratedRed: 0.88, green: 0.94, blue: 1.0, alpha: 0.075)
            context.setStrokeColor(hue.cgColor)
            context.setLineWidth(index.isMultiple(of: 7) ? 0.9 : 0.55)
            context.move(to: CGPoint(x: center.x + cos(angle) * irisRadiusX * innerFactor,
                                     y: center.y + sin(angle) * irisRadiusY * innerFactor))
            context.addQuadCurve(to: CGPoint(x: center.x + cos(angle) * irisRadiusX * outerFactor,
                                             y: center.y + sin(angle) * irisRadiusY * outerFactor),
                                 control: CGPoint(x: center.x + cos(bend) * irisRadiusX * middleFactor,
                                                  y: center.y + sin(bend) * irisRadiusY * middleFactor))
            context.strokePath()
        }
        context.restoreGState()

        let pupilEdge = NSBezierPath(ovalIn: pupil)
        pupilEdge.lineWidth = 0.8
        NSColor(calibratedRed: 0.56, green: 0.79, blue: 0.95, alpha: 0.36).setStroke()
        pupilEdge.stroke()
        eye.lineWidth = 1.8
        (isReading ? NSColor.systemOrange : NSColor.systemBlue).withAlphaComponent(0.78).setStroke()
        eye.stroke()
        NSColor.white.withAlphaComponent(0.74).setFill()
        NSBezierPath(ovalIn: CGRect(x: center.x - irisRadiusX * 0.72,
                                    y: center.y + irisRadiusY * 0.53,
                                    width: 4.6, height: 4.6)).fill()
        NSColor.white.withAlphaComponent(0.38).setFill()
        NSBezierPath(ovalIn: CGRect(x: center.x - irisRadiusX * 0.66,
                                    y: center.y + irisRadiusY * 0.60,
                                    width: 1.8, height: 1.8)).fill()
    }
}

@MainActor
private final class WordMagnifierProbe: NSObject, NSApplicationDelegate {
    private let lensSize = CGSize(width: 190, height: 122)
    private let bridge = WordTranslationBridge()
    private let selectionBridge = SelectionTranslationBridge()
    private var panel: NSPanel!
    private var translationPanel: NSPanel!
    private var contextLabel: NSTextField!
    private var wordLabel: NSTextField!
    private var view: EyeLensView!
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var displays: [CGDirectDisplayID: SCDisplay] = [:]
    private var ownWindow: SCWindow?
    private var cardWindow: SCWindow?
    private var hotKeyHandler: EventHandlerRef?
    private var showHotKey: EventHotKeyRef?
    private var escapeHotKey: EventHotKeyRef?
    private var lockFD: Int32 = -1
    private var scanning = false
    private var lastPointer = CGPoint.zero
    private var lastMoveAt = 0.0
    private var generation = 0
    private var inspectedGeneration = -1
    private var nextInspectionAt = 0.0
    private var consecutiveMisses = 0
    private var translationFailures = 0
    private var currentSentence: String?
    private var currentAnchor: String?
    private var currentFocusLine: String?
    private var currentFocusWordIndex: Int?
    private var pendingTranslationKey: String?
    private var translationCache: [String: FocusedTranslation] = [:]
    private var pasteboardChangeCount = 0
    private var nextPasteboardPollAt = 0.0
    private var clipboardHint: String?
    private var clipboardHintDeadline = 0.0
    private var clipboardHintMisses = 0
    private var selectionRequestID = 0
    private var pendingSelectionText: String?
    private var selectionCache: [String: String] = [:]
    private var showingSelectionCard = false
    private var fixedPoint: CGPoint? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--fixed-point"), index + 2 < args.count,
              let x = Double(args[index + 1]), let y = Double(args[index + 2]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let lockPath = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("EasyLensProbe.lock").path
        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR, mode_t(0o600))
        var lock = Darwin.flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard fd >= 0, Darwin.fcntl(fd, F_SETLK, &lock) == 0 else {
            if fd >= 0 { Darwin.close(fd) }
            print("ERROR another EasyLens probe is running; quit its EL menu first")
            NSApp.terminate(nil)
            return
        }
        lockFD = fd
        let pointer = fixedPoint ?? NSEvent.mouseLocation
        lastPointer = pointer
        lastMoveAt = uptime()
        panel = NSPanel(contentRect: frame(around: pointer), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let lensBounds = CGRect(origin: .zero, size: lensSize)
        let container = NSView(frame: lensBounds)
        let frost = NSVisualEffectView(frame: lensBounds)
        frost.material = .hudWindow
        frost.blendingMode = .behindWindow
        frost.state = .active
        frost.wantsLayer = true
        let eyeRect = lensBounds.insetBy(dx: 3, dy: 3)
        let clearCenter = CGRect(x: eyeRect.midX - eyeRect.height * 0.60,
                                 y: eyeRect.midY - eyeRect.height * 0.40,
                                 width: eyeRect.height * 1.20,
                                 height: eyeRect.height * 0.80)
        let frostPath = CGMutablePath()
        frostPath.addPath(EyeLensView.eyePath(in: eyeRect).cgPath)
        frostPath.addEllipse(in: clearCenter)
        let frostMask = CAShapeLayer()
        frostMask.frame = lensBounds
        frostMask.path = frostPath
        frostMask.fillRule = .evenOdd
        frost.layer?.mask = frostMask
        container.addSubview(frost)
        view = EyeLensView(frame: lensBounds)
        container.addSubview(view)
        panel.contentView = container
        translationPanel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 380, height: 100),
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        translationPanel.level = .floating
        translationPanel.backgroundColor = .clear
        translationPanel.isOpaque = false
        translationPanel.hasShadow = true
        translationPanel.ignoresMouseEvents = true
        translationPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let card = NSView(frame: CGRect(x: 0, y: 0, width: 380, height: 100))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.94).cgColor
        card.layer?.cornerRadius = 14
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.5).cgColor
        translationPanel.contentView = card
        contextLabel = NSTextField(labelWithString: "")
        contextLabel.font = .systemFont(ofSize: 16, weight: .medium)
        contextLabel.textColor = .white
        contextLabel.lineBreakMode = .byWordWrapping
        contextLabel.maximumNumberOfLines = 0
        card.addSubview(contextLabel)
        wordLabel = NSTextField(labelWithString: "")
        wordLabel.font = .systemFont(ofSize: 12)
        wordLabel.textColor = NSColor(calibratedWhite: 0.75, alpha: 1)
        card.addSubview(wordLabel)
        translationPanel.orderOut(nil)
        let taskView = NSHostingView(rootView: TranslationTaskView(bridge: bridge))
        taskView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        container.addSubview(taskView)
        let selectedTaskView = NSHostingView(
            rootView: SelectionTranslationTaskView(bridge: selectionBridge))
        selectedTaskView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        container.addSubview(selectedTaskView)
        bridge.onResult = { [weak self] generation, result in
            self?.receiveTranslation(generation: generation, result: result)
        }
        selectionBridge.onResult = { [weak self] requestID, result in
            self?.receiveSelectionTranslation(requestID: requestID, result: result)
        }
        panel.orderOut(nil)
        translationPanel.orderOut(nil)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "EL◉"
        let menu = NSMenu()
        let show = NSMenuItem(title: "Toggle eye lens (⌃⌥L)",
                              action: #selector(toggle), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let hide = NSMenuItem(title: "Hide lens (Esc)", action: #selector(hide), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit EasyLens probe", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        installHotKeys()
        print("CONTEXT_EYE_PROBE ⌃⌥L toggles eye lens; Esc hides; EL◉ menu quits")
        print("NO_CLOUD_CALLS screenshots_saved=0")
        fflush(stdout)
        if CommandLine.arguments.contains("--show-on-launch") { showLens() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let showHotKey { UnregisterEventHotKey(showHotKey) }
        if let escapeHotKey { UnregisterEventHotKey(escapeHotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        if lockFD >= 0 {
            var lock = Darwin.flock()
            lock.l_type = Int16(F_UNLCK)
            lock.l_whence = Int16(SEEK_SET)
            _ = Darwin.fcntl(lockFD, F_SETLK, &lock)
            Darwin.close(lockFD)
        }
    }

    private func installHotKeys() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var identity = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identity)
            guard result == noErr else { return result }
            let probe = Unmanaged<WordMagnifierProbe>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                if identity.id == 1 { probe.toggle() }
                if identity.id == 2 { probe.hide() }
            }
            return noErr
        }, 1, &eventType, opaque, &hotKeyHandler)
        guard status == noErr else { print("ERROR hotkey handler status=\(status)"); return }
        let showID = EventHotKeyID(signature: OSType(0x454C574D), id: 1)
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey),
                                            showID, GetApplicationEventTarget(), 0, &showHotKey)
        print(registered == noErr ? "WAKE_HOTKEY_REGISTERED=⌃⌥L" :
              "ERROR wake hotkey status=\(registered)")
    }

    private func registerEscape() {
        guard escapeHotKey == nil else { return }
        let id = EventHotKeyID(signature: OSType(0x454C574D), id: 2)
        let status = RegisterEventHotKey(UInt32(kVK_Escape), 0, id,
                                         GetApplicationEventTarget(), 0, &escapeHotKey)
        if status != noErr { print("ERROR Escape hotkey status=\(status)") }
    }

    private func releaseEscape() {
        if let escapeHotKey { UnregisterEventHotKey(escapeHotKey); self.escapeHotKey = nil }
    }

    @objc private func toggle() {
        panel.isVisible ? hide() : showLens()
    }

    private func showLens() {
        let pointer = fixedPoint ?? NSEvent.mouseLocation
        let pasteboard = NSPasteboard.general
        pasteboardChangeCount = pasteboard.changeCount
        nextPasteboardPollAt = 0
        // A sentence may have been copied before the lens was opened. Reuse
        // only multiword text; visual row and local-word checks still gate it.
        clipboardHint = pasteboard.string(forType: .string).flatMap(eligibleClipboardHint)
            .flatMap { clipboardWords($0).count > 1 ? $0 : nil }
        clipboardHintDeadline = uptime() + 5
        clipboardHintMisses = 0
        selectionRequestID += 1
        pendingSelectionText = nil
        showingSelectionCard = false
        lastPointer = pointer
        lastMoveAt = uptime()
        generation += 1
        inspectedGeneration = -1
        nextInspectionAt = 0
        consecutiveMisses = 0
        translationFailures = 0
        currentSentence = nil
        currentAnchor = nil
        currentFocusLine = nil
        currentFocusWordIndex = nil
        pendingTranslationKey = nil
        translationPanel.orderOut(nil)
        panel.setFrame(frame(around: pointer), display: true)
        panel.orderFrontRegardless()
        registerEscape()
        timer?.invalidate()
        timer = Timer.scheduledTimer(timeInterval: 1.0 / 60.0, target: self,
                                     selector: #selector(tick), userInfo: nil, repeats: true)
        Task { await prepareCapture() }
        print("LENS_SHOWN preexistingSelectionLength=\(clipboardHint?.count ?? 0)")
        fflush(stdout)
    }

    @objc private func hide() {
        guard panel.isVisible else { return }
        generation += 1
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
        translationPanel.orderOut(nil)
        releaseEscape()
        currentSentence = nil
        currentAnchor = nil
        currentFocusLine = nil
        currentFocusWordIndex = nil
        pendingTranslationKey = nil
        clipboardHint = nil
        clipboardHintMisses = 0
        selectionRequestID += 1
        pendingSelectionText = nil
        showingSelectionCard = false
        print("LENS_HIDDEN")
        fflush(stdout)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func screen(at point: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) })
    }

    private func frame(around pointer: CGPoint) -> CGRect {
        let screen = screen(at: pointer) ?? NSScreen.main ?? NSScreen.screens[0]
        let x = max(screen.frame.minX, min(pointer.x - lensSize.width / 2,
                                          screen.frame.maxX - lensSize.width))
        let y = max(screen.frame.minY, min(pointer.y - lensSize.height / 2,
                                          screen.frame.maxY - lensSize.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: lensSize)
    }

    private func pollClipboard() {
        guard uptime() >= nextPasteboardPollAt else { return }
        nextPasteboardPollAt = uptime() + 0.2
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != pasteboardChangeCount else { return }
        pasteboardChangeCount = pasteboard.changeCount
        selectionRequestID += 1
        pendingSelectionText = nil
        showingSelectionCard = false
        clipboardHint = pasteboard.string(forType: .string).flatMap(eligibleClipboardHint)
        clipboardHintDeadline = uptime() + 5
        clipboardHintMisses = 0
        generation += 1
        inspectedGeneration = -1
        nextInspectionAt = 0
        pendingTranslationKey = nil
        translationPanel.orderOut(nil)
        if let clipboardHint {
            print("CLIPBOARD_HINT accepted length=\(clipboardHint.count)")
        } else {
            print("CLIPBOARD_HINT skipped=non-english-or-unsupported")
        }
        fflush(stdout)
    }

    private func endClipboardHint(reason: String) {
        guard clipboardHint != nil else { return }
        clipboardHint = nil
        clipboardHintMisses = 0
        selectionRequestID += 1
        pendingSelectionText = nil
        if showingSelectionCard {
            translationPanel.orderOut(nil)
            showingSelectionCard = false
        }
        print("CLIPBOARD_HINT ended reason=\(reason)")
        fflush(stdout)
    }

    private func showFocusCard(_ chinese: String, anchor: String, basis: String,
                               pointer: CGPoint) {
        showingSelectionCard = false
        let width: CGFloat = min(300, max(160, CGFloat(max(anchor.count + basis.count,
                                                           chinese.count)) * 15 + 36))
        let height: CGFloat = 72
        let contentWidth = width - 32
        translationPanel.setContentSize(CGSize(width: width, height: height))
        translationPanel.contentView?.frame = CGRect(x: 0, y: 0, width: width, height: height)
        wordLabel.stringValue = "\(anchor) · \(basis)"
        wordLabel.frame = CGRect(x: 16, y: 44, width: contentWidth, height: 18)
        contextLabel.font = .systemFont(ofSize: 16, weight: .medium)
        contextLabel.stringValue = chinese
        contextLabel.frame = CGRect(x: 16, y: 10, width: contentWidth, height: 30)
        guard let screen = screen(at: pointer) else { return }
        let eyeFrame = panel.frame
        let x = max(screen.frame.minX + 6,
                    min(eyeFrame.midX - width / 2, screen.frame.maxX - width - 6))
        let below = eyeFrame.minY - height - 8
        let y = below >= screen.frame.minY + 6 ? below : eyeFrame.maxY + 8
        translationPanel.setFrameOrigin(CGPoint(x: x, y: y))
        translationPanel.orderFrontRegardless()
    }

    private func showSelectionCard(_ chinese: String, pointer: CGPoint) {
        guard let screen = screen(at: pointer) else { return }
        showingSelectionCard = true
        let width: CGFloat = min(420, max(250, screen.frame.width - 12))
        let contentWidth = width - 32
        let font = NSFont.systemFont(ofSize: 15, weight: .medium)
        let measured = (chinese as NSString).boundingRect(
            with: CGSize(width: contentWidth, height: 500),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]).height
        let textHeight = min(210, max(34, ceil(measured) + 4))
        let height = textHeight + 54
        translationPanel.setContentSize(CGSize(width: width, height: height))
        translationPanel.contentView?.frame = CGRect(x: 0, y: 0, width: width, height: height)
        wordLabel.stringValue = "选区翻译"
        wordLabel.frame = CGRect(x: 16, y: height - 34, width: contentWidth, height: 18)
        contextLabel.font = font
        contextLabel.stringValue = chinese
        contextLabel.frame = CGRect(x: 16, y: 12, width: contentWidth, height: textHeight)
        let eyeFrame = panel.frame
        let x = max(screen.frame.minX + 6,
                    min(eyeFrame.midX - width / 2, screen.frame.maxX - width - 6))
        let below = eyeFrame.minY - height - 8
        let y = below >= screen.frame.minY + 6 ? below :
            min(eyeFrame.maxY + 8, screen.frame.maxY - height - 6)
        translationPanel.setFrameOrigin(CGPoint(x: x, y: y))
        translationPanel.orderFrontRegardless()
    }

    private func receiveSelectionTranslation(requestID: Int,
                                             result: Result<(String, Double), Error>) {
        guard requestID == selectionRequestID, let source = pendingSelectionText else { return }
        pendingSelectionText = nil
        switch result {
        case .success(let (chinese, elapsed)):
            let translated = chinese.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty else {
                endClipboardHint(reason: "empty-selection-translation")
                inspectedGeneration = -1
                nextInspectionAt = 0
                return
            }
            selectionCache[source] = translated
            if panel.isVisible, clipboardHint == source,
               let currentAnchor, let currentFocusLine, let currentFocusWordIndex,
               selectedTextAtFocus(source, anchor: currentAnchor,
                                   focusLine: currentFocusLine,
                                   focusWordIndex: currentFocusWordIndex) != nil {
                showSelectionCard(translated, pointer: fixedPoint ?? NSEvent.mouseLocation)
            }
            print(String(format: "SELECTION_TRANSLATION translatedMs=%.1f resolved=yes cloudCalls=0",
                         elapsed))
        case .failure(let error):
            print("SELECTION_TRANSLATION_ERROR=\(error)")
            endClipboardHint(reason: "selection-translation-error")
            inspectedGeneration = -1
            nextInspectionAt = 0
        }
        fflush(stdout)
    }

    private func wordScanFrame(around pointer: CGPoint, on screen: NSScreen) -> CGRect {
        let width = min(CGFloat(1800), screen.frame.width)
        let height = min(CGFloat(220), screen.frame.height)
        let x = max(screen.frame.minX, min(pointer.x - width / 2,
                                          screen.frame.maxX - width))
        let y = max(screen.frame.minY, min(pointer.y - height / 2,
                                          screen.frame.maxY - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func prepareCapture() async {
        guard panel.isVisible else { return }
        do {
            try await Task.sleep(nanoseconds: 160_000_000)
            translationPanel.alphaValue = 0.01
            translationPanel.orderFrontRegardless()
            defer {
                translationPanel.orderOut(nil)
                translationPanel.alphaValue = 1
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                                onScreenWindowsOnly: false)
            displays = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
            ownWindow = content.windows.first { $0.windowID == CGWindowID(panel.windowNumber) }
            cardWindow = content.windows.first {
                $0.windowID == CGWindowID(translationPanel.windowNumber)
            }
            guard ownWindow != nil else {
                throw NSError(domain: "EasyLens", code: 1)
            }
            print("CAPTURE_READY displays=\(displays.count) lensWindow=\(panel.windowNumber) cardExcluded=\(cardWindow != nil)")
            fflush(stdout)
        } catch {
            print("CAPTURE_SETUP_ERROR=\(error)")
            fflush(stdout)
        }
    }

    @objc private func tick() {
        guard panel.isVisible else { return }
        let pointer = fixedPoint ?? NSEvent.mouseLocation
        pollClipboard()
        if clipboardHint != nil && uptime() >= clipboardHintDeadline {
            endClipboardHint(reason: "expired")
            generation += 1
            inspectedGeneration = -1
            nextInspectionAt = 0
            pendingTranslationKey = nil
        }
        let nextFrame = frame(around: pointer)
        if panel.frame.origin != nextFrame.origin {
            panel.setFrame(nextFrame, display: true)
        }
        if hypot(pointer.x - lastPointer.x, pointer.y - lastPointer.y) >= 3 {
            lastPointer = pointer
            lastMoveAt = uptime()
            generation += 1
            inspectedGeneration = -1
            nextInspectionAt = 0
            consecutiveMisses = 0
            translationFailures = 0
            currentSentence = nil
            currentAnchor = nil
            currentFocusLine = nil
            currentFocusWordIndex = nil
            pendingTranslationKey = nil
            translationPanel.orderOut(nil)
            view.isReading = false
        }
        guard !scanning, uptime() - lastMoveAt >= 0.10,
              inspectedGeneration != generation, uptime() >= nextInspectionAt,
              let screen = screen(at: pointer), let id = displayID(for: screen),
              let display = displays[id], let ownWindow else { return }
        let excluded = [ownWindow] + (cardWindow.map { [$0] } ?? [])
        let filter = SCContentFilter(display: display,
                                     excludingWindows: excluded)
        let current = generation
        inspectedGeneration = current
        scanning = true
        view.isReading = currentSentence == nil
        Task { await inspectFocus(pointer: pointer, generation: current,
                                  screen: screen, filter: filter) }
    }

    private func inspectFocus(pointer: CGPoint, generation current: Int,
                              screen: NSScreen, filter: SCContentFilter) async {
        defer { scanning = false }
        do {
            // The OCR request runs separately, so it cannot hold the visual frame gate.
            let scan = wordScanFrame(around: pointer, on: screen)
            let scanConfig = SCStreamConfiguration()
            scanConfig.sourceRect = CGRect(x: scan.minX - screen.frame.minX,
                                           y: screen.frame.maxY - scan.maxY,
                                           width: scan.width, height: scan.height)
            let ocrScale = min(screen.backingScaleFactor, 1.5)
            scanConfig.width = Int(scan.width * ocrScale)
            scanConfig.height = Int(scan.height * ocrScale)
            scanConfig.showsCursor = false
            let scanStart = uptime()
            let scanImage = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                       configuration: scanConfig)
            let scanMs = ms(scanStart)
            let focus = CGPoint(x: (pointer.x - scan.minX) / scan.width,
                                y: (pointer.y - scan.minY) / scan.height)
            let hint = clipboardHint
            let (passage, ocrMs) = try await Task.detached(priority: .userInitiated) {
                try passageAtCenter(scanImage, focus: focus, clipboardHint: hint)
            }.value
            guard panel.isVisible, current == generation else { return }
            view.isReading = false
            guard let passage else {
                if showingSelectionCard {
                    translationPanel.orderOut(nil)
                    showingSelectionCard = false
                }
                if let hint = clipboardHint, clipboardWords(hint).count == 1 {
                    clipboardHintMisses += 1
                    if clipboardHintMisses >= 2 {
                        endClipboardHint(reason: "no-visual-focus")
                    }
                }
                if currentSentence != nil {
                    generation += 1
                    currentSentence = nil
                    currentAnchor = nil
                    currentFocusLine = nil
                    currentFocusWordIndex = nil
                    pendingTranslationKey = nil
                    translationPanel.orderOut(nil)
                    print("FOCUS_CONTENT_CHANGED target=none")
                }
                consecutiveMisses += 1
                inspectedGeneration = -1
                nextInspectionAt = uptime() + min(0.45 * pow(1.6, Double(consecutiveMisses - 1)), 2.0)
                print(String(format: "SENTENCE_FOCUS none scanMs=%.1f ocrMs=%.1f", scanMs, ocrMs))
                fflush(stdout)
                return
            }
            consecutiveMisses = 0
            if let hint = clipboardHint {
                if hintSupportsFocus(hint, anchor: passage.anchor) {
                    clipboardHintMisses = 0
                    print("CLIPBOARD_HINT corroborated=true")
                } else if clipboardWords(hint).count == 1 {
                    endClipboardHint(reason: "different-visual-focus")
                }
            }
            if currentAnchor != passage.anchor || currentSentence != passage.sentence {
                generation += 1
                pendingTranslationKey = nil
                translationPanel.orderOut(nil)
                print("FOCUS_CONTENT_CHANGED target=word")
            }
            currentSentence = passage.sentence
            currentAnchor = passage.anchor
            currentFocusLine = passage.focusLine
            currentFocusWordIndex = passage.focusWordIndex
            // The page may scroll beneath a stationary lens. Recheck without
            // restarting a translation request for an unchanged passage.
            inspectedGeneration = -1
            nextInspectionAt = uptime() + 0.6
            print(String(format: "SENTENCE_FOCUS found anchorLength=%d sentenceLength=%d distance=%.3f scanMs=%.1f ocrMs=%.1f",
                         passage.anchor.count, passage.sentence.count, passage.distance, scanMs, ocrMs))
            fflush(stdout)
            let selected = clipboardHint.flatMap {
                selectedTextAtFocus($0, anchor: passage.anchor,
                                    focusLine: passage.focusLine,
                                    focusWordIndex: passage.focusWordIndex)
            }
            if let selected {
                if let cached = selectionCache[selected] {
                    showSelectionCard(cached, pointer: pointer)
                } else if pendingSelectionText != selected {
                    selectionRequestID += 1
                    pendingSelectionText = selected
                    selectionBridge.translate(selected, requestID: selectionRequestID)
                    print("SELECTION_TRANSLATION requested length=\(selected.count) cloudCalls=0")
                }
                return
            }
            if let hint = clipboardHint, clipboardWords(hint).count > 1 {
                let reason = passage.focusWordIndex < 0 ? "no-direct-hit" : "focus-row-mismatch"
                print(String(format: "SELECTION_FOCUS skipped reason=%@ distance=%.3f hintWords=%d rowWords=%d",
                             reason, passage.distance, clipboardWords(hint).count,
                             clipboardWords(passage.focusLine).count))
            }
            if showingSelectionCard {
                translationPanel.orderOut(nil)
                showingSelectionCard = false
            }
            let cacheKey = passage.anchor.lowercased() + "\n" + passage.sentence
            if let literal = passage.literalTranslation {
                let translation = FocusedTranslation(chinese: literal, basis: "时间表达")
                translationCache[cacheKey] = translation
                showFocusCard(literal, anchor: passage.anchor,
                              basis: translation.basis, pointer: pointer)
                print("FOCUS_TRANSLATION resolved=yes basis=时间表达 cloudCalls=0")
                fflush(stdout)
                return
            }
            if let cached = translationCache[cacheKey] {
                if let chinese = cached.chinese {
                    showFocusCard(chinese, anchor: passage.anchor,
                                  basis: cached.basis, pointer: pointer)
                }
                print("FOCUS_TRANSLATION cacheHit=true resolved=\(cached.chinese != nil) basis=\(cached.basis) cloudCalls=0")
                fflush(stdout)
            } else if pendingTranslationKey != cacheKey {
                pendingTranslationKey = cacheKey
                bridge.translate(anchor: passage.anchor, sentence: passage.sentence,
                                 maskedSentence: passage.maskedSentence,
                                 localContext: passage.localContext,
                                 maskedLocalContext: passage.maskedLocalContext,
                                 microContext: passage.microContext,
                                 maskedMicroContext: passage.maskedMicroContext,
                                 prefixContext: passage.prefixContext,
                                 maskedPrefixContext: passage.maskedPrefixContext,
                                 generation: generation)
            }
        } catch {
            if current == generation {
                view.isReading = false
                inspectedGeneration = -1
                nextInspectionAt = uptime() + 0.8
            }
            print("FOCUS_SCAN_ERROR=\(error)")
            fflush(stdout)
        }
    }

    private func receiveTranslation(generation current: Int,
                                    result: Result<(FocusedTranslation, Double), Error>) {
        guard panel.isVisible, current == generation,
              let currentSentence, let currentAnchor else { return }
        pendingTranslationKey = nil
        if let hint = clipboardHint, let currentFocusLine, let currentFocusWordIndex,
           selectedTextAtFocus(hint, anchor: currentAnchor,
                               focusLine: currentFocusLine,
                               focusWordIndex: currentFocusWordIndex) != nil { return }
        switch result {
        case .success(let (translation, elapsed)):
            translationFailures = 0
            let cacheKey = currentAnchor.lowercased() + "\n" + currentSentence
            translationCache[cacheKey] = translation
            if let chinese = translation.chinese {
                showFocusCard(chinese, anchor: currentAnchor,
                              basis: translation.basis,
                              pointer: fixedPoint ?? NSEvent.mouseLocation)
            } else {
                translationPanel.orderOut(nil)
            }
            print(String(format: "FOCUS_TRANSLATION translatedMs=%.1f resolved=%@ basis=%@ cloudCalls=0",
                         elapsed, translation.chinese == nil ? "no" : "yes",
                         translation.basis))
        case .failure(let error):
            print("SENTENCE_TRANSLATION_ERROR=\(error)")
            if translationFailures == 0 {
                translationFailures = 1
                inspectedGeneration = -1
                nextInspectionAt = uptime() + 0.8
            }
        }
        fflush(stdout)
    }
}

@MainActor
private final class FocusTranslationSelfTest: NSObject, NSApplicationDelegate {
    private let bridge = WordTranslationBridge()
    private var window: NSWindow!
    private let anchor: String
    private let sentence: String
    private let masked: String
    private let local: String
    private let maskedLocal: String
    private let micro: String
    private let maskedMicro: String
    private let prefix: String
    private let maskedPrefix: String

    init(anchor: String, sentence: String, masked: String,
         local: String, maskedLocal: String,
         micro: String, maskedMicro: String,
         prefix: String, maskedPrefix: String) {
        self.anchor = anchor
        self.sentence = sentence
        self.masked = masked
        self.local = local
        self.maskedLocal = maskedLocal
        self.micro = micro
        self.maskedMicro = maskedMicro
        self.prefix = prefix
        self.maskedPrefix = maskedPrefix
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 120, height: 80),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: TranslationTaskView(bridge: bridge))
        window.orderFront(nil)
        bridge.onResult = { _, result in
            switch result {
            case .success(let (translation, elapsed)):
                print(String(format: "FOCUS_SELF_TEST result=%@ basis=%@ translatedMs=%.1f",
                             translation.chinese ?? "unresolved", translation.basis, elapsed))
            case .failure(let error):
                print("FOCUS_SELF_TEST_ERROR=\(error)")
            }
            fflush(stdout)
            NSApp.terminate(nil)
        }
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            bridge.translate(anchor: anchor, sentence: sentence,
                             maskedSentence: masked, localContext: local,
                             maskedLocalContext: maskedLocal,
                             microContext: micro, maskedMicroContext: maskedMicro,
                             prefixContext: prefix,
                             maskedPrefixContext: maskedPrefix,
                             generation: 0)
        }
    }
}

@MainActor
private final class SelectionTranslationSelfTest: NSObject, NSApplicationDelegate {
    private let bridge = SelectionTranslationBridge()
    private let source: String
    private var window: NSWindow!

    init(source: String) { self.source = source }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 120, height: 80),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SelectionTranslationTaskView(bridge: bridge))
        window.orderFront(nil)
        bridge.onResult = { _, result in
            switch result {
            case .success(let (translated, elapsed)):
                print(String(format: "SELECTION_SELF_TEST result=%@ translatedMs=%.1f",
                             translated, elapsed))
            case .failure(let error):
                print("SELECTION_SELF_TEST_ERROR=\(error)")
            }
            fflush(stdout)
            NSApp.terminate(nil)
        }
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            bridge.translate(source, requestID: 1)
        }
    }
}

@main
private enum WordMagnifierMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--translate-selection"), index + 1 < args.count {
            let app = NSApplication.shared
            let delegate = SelectionTranslationSelfTest(source: args[index + 1])
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
            return
        }
        if let index = args.firstIndex(of: "--translate-focus-both"), index + 9 < args.count {
            let app = NSApplication.shared
            let delegate = FocusTranslationSelfTest(anchor: args[index + 1],
                                                    sentence: args[index + 2],
                                                    masked: args[index + 3],
                                                    local: args[index + 4],
                                                    maskedLocal: args[index + 5],
                                                    micro: args[index + 6],
                                                    maskedMicro: args[index + 7],
                                                    prefix: args[index + 8],
                                                    maskedPrefix: args[index + 9])
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
            return
        }
        if let index = args.firstIndex(of: "--translate-focus-micro"), index + 7 < args.count {
            let app = NSApplication.shared
            let delegate = FocusTranslationSelfTest(anchor: args[index + 1],
                                                    sentence: args[index + 2],
                                                    masked: args[index + 3],
                                                    local: args[index + 4],
                                                    maskedLocal: args[index + 5],
                                                    micro: args[index + 6],
                                                    maskedMicro: args[index + 7],
                                                    prefix: args[index + 4],
                                                    maskedPrefix: args[index + 5])
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
            return
        }
        if let index = args.firstIndex(of: "--translate-focus"), index + 5 < args.count {
            let app = NSApplication.shared
            let delegate = FocusTranslationSelfTest(anchor: args[index + 1],
                                                    sentence: args[index + 2],
                                                    masked: args[index + 3],
                                                    local: args[index + 4],
                                                    maskedLocal: args[index + 5],
                                                    micro: args[index + 4],
                                                    maskedMicro: args[index + 5],
                                                    prefix: args[index + 4],
                                                    maskedPrefix: args[index + 5])
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
            return
        }
        if let index = args.firstIndex(of: "--derive-focus"), index + 5 < args.count {
            let chinese = focusedChineseWord(full: args[index + 1],
                                             masked: args[index + 2],
                                             local: args[index + 3],
                                             maskedLocal: args[index + 4],
                                             direct: args[index + 5])
            print("FOCUS_DERIVATION=\(chinese ?? "unresolved")")
            return
        }
        if let index = args.firstIndex(of: "--validate-word"), index + 1 < args.count {
            print("WORD_VALIDATION=\(validatedEnglishWord(args[index + 1]) ?? "unresolved")")
            return
        }
        if let index = args.firstIndex(of: "--inspect-clipboard-hint"), index + 2 < args.count {
            let hint = eligibleClipboardHint(args[index + 1])
            let anchor = args[index + 2]
            let raw = index + 3 < args.count ? args[index + 3] : anchor
            let supports = hint.map { hintSupportsFocus($0, anchor: anchor) } ?? false
            let outcome = focusedWordWithHint(raw, hint: hint)
            print("CLIPBOARD_HINT_INSPECTION eligible=\(hint != nil) supports=\(supports) resolved=\(outcome.word ?? "none") usedHint=\(outcome.usedHint)")
            return
        }
        if let index = args.firstIndex(of: "--inspect-selection-focus"), index + 4 < args.count,
           let wordIndex = Int(args[index + 4]) {
            let hint = eligibleClipboardHint(args[index + 1])
            let selected = hint.flatMap {
                selectedTextAtFocus($0, anchor: args[index + 2],
                                    focusLine: args[index + 3],
                                    focusWordIndex: wordIndex)
            }
            print("SELECTION_FOCUS_INSPECTION promotes=\(selected != nil)")
            return
        }
        if let index = args.firstIndex(of: "--inspect-image"), index + 3 < args.count,
           let x = Double(args[index + 2]), let y = Double(args[index + 3]),
           let source = CGImageSourceCreateWithURL(
               URL(fileURLWithPath: args[index + 1]) as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let width = min(1800.0, Double(image.width))
            let height = min(220.0, Double(image.height))
            let area = CGRect(x: max(0, min(x - width / 2, Double(image.width) - width)),
                              y: max(0, min(y - height / 2, Double(image.height) - height)),
                              width: width, height: height).integral
            if let cropped = image.cropping(to: area) {
                do {
                    let focus = CGPoint(x: (x - area.minX) / area.width,
                                        y: 1 - (y - area.minY) / area.height)
                    let hintIndex = args.firstIndex(of: "--clipboard-hint")
                    let hint = hintIndex.flatMap { $0 + 1 < args.count ?
                        eligibleClipboardHint(args[$0 + 1]) : nil }
                    let (passage, ocrMs) = try passageAtCenter(
                        cropped, focus: focus, debug: args.contains("--show-ocr"),
                        accurate: args.contains("--accurate-ocr"), clipboardHint: hint)
                    print(String(format: "SENTENCE_INSPECTION found=%@ length=%d ocrMs=%.1f",
                                 passage == nil ? "no" : "yes", passage?.sentence.count ?? 0, ocrMs))
                    if args.contains("--show-word"), let passage {
                        print("ANCHOR=\(passage.anchor)")
                        if let literal = passage.literalTranslation {
                            print("LITERAL_TRANSLATION=\(literal)")
                        }
                        print("SENTENCE=\(passage.sentence)")
                        print("MASKED=\(passage.maskedSentence)")
                        print("LOCAL=\(passage.localContext)")
                        print("MASKED_LOCAL=\(passage.maskedLocalContext)")
                        print("MICRO=\(passage.microContext)")
                        print("MASKED_MICRO=\(passage.maskedMicroContext)")
                        print("PREFIX=\(passage.prefixContext)")
                        print("MASKED_PREFIX=\(passage.maskedPrefixContext)")
                    }
                } catch { print("WORD_INSPECTION_ERROR=\(error)") }
            }
            return
        }
        let app = NSApplication.shared
        let delegate = WordMagnifierProbe()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

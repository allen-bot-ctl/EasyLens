// Migrated from the validated macOS lens prototype.
import AppKit
import NaturalLanguage
import Vision

// Paths and filenames can appear inside otherwise translatable prose. Exclude
// their own glyphs, not the entire OCR row (whose Chinese text may also be
// misread as punctuation such as '/').
private let inlinePathRegex = try! NSRegularExpression(
    pattern: "(?:[A-Za-z0-9_.*~-]+[\\\\/])+[A-Za-z0-9_.*~+#-]+|(?:[A-Za-z0-9_-]+\\.)+(?:app|swift|mjs|js|json|py|md|tgz|html)\\b",
    options: [.caseInsensitive])

func inlinePathRanges(_ text: String) -> [NSRange] {
    inlinePathRegex.matches(in: text,
                            range: NSRange(location: 0, length: (text as NSString).length))
        .map(\.range)
}

func excludingInlinePaths(_ text: String) -> String {
    let result = NSMutableString(string: text)
    for range in inlinePathRanges(text).reversed() {
        result.replaceCharacters(in: range, with: String(repeating: " ", count: range.length))
    }
    return result as String
}

func passageAtCenter(_ image: CGImage, focus: CGPoint,
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
    var found: [(row: Int, anchor: String, range: NSRange,
                 distance: CGFloat, centerDistance: CGFloat,
                 literalTranslation: String?, hinted: Bool)] = []
    for (rowIndex, row) in rows.enumerated() {
        let excludedRanges = inlinePathRanges(row.text)
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
            guard !excludedRanges.contains(where: {
                NSIntersectionRange(match.range, $0).length > 0
            }) else { continue }
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
    let focusRow = rows[focused.row].box
    let rowPadding = min(focusRow.height * 0.25, 0.025)
    if focusRow.insetBy(dx: -0.003, dy: -rowPadding).contains(focus) {
        focusWordIndex = regex.matches(
            in: focusedLine,
            range: NSRange(location: 0, length: (focusedLine as NSString).length)
        ).firstIndex(where: { NSIntersectionRange($0.range, focused.range).length > 0 }) ?? -1
    } else {
        // Selection promotion needs the center on the OCR line itself;
        // a nearby word on the row above or below is not enough.
        focusWordIndex = -1
    }
    // Word choice may favor a glyph on the neighboring row at a line break.
    // Classify the selection against the row actually under the center, then
    // use that row's nearest recognized word only as a text alignment anchor.
    let centerRows = rows.indices.filter { index in
        let box = rows[index].box
        let padding = min(box.height * 0.25, 0.025)
        return box.insetBy(dx: -0.003, dy: -padding).contains(focus)
    }
    let selectionRow = centerRows.min {
        let a = rows[$0].box
        let b = rows[$1].box
        let aGap = max(a.minY - focus.y, 0, focus.y - a.maxY)
        let bGap = max(b.minY - focus.y, 0, focus.y - b.maxY)
        return aGap == bGap ? abs(a.midY - focus.y) < abs(b.midY - focus.y) : aGap < bGap
    }
    if let literal = focused.literalTranslation {
        let masked = (focused.anchor as NSString).replacingCharacters(
            in: NSRange(location: 0, length: (focused.anchor as NSString).length),
            with: focusMarker)
        return (FocusedPassage(anchor: focused.anchor, sentence: focused.anchor,
                               focusLine: focusedLine, focusWordIndex: focusWordIndex,
                               selectionFocusRowBox: selectionRow.map { rows[$0].box },
                               maskedSentence: masked, localContext: focused.anchor,
                               maskedLocalContext: masked, microContext: focused.anchor,
                               maskedMicroContext: masked, prefixContext: focused.anchor,
                               maskedPrefixContext: masked,
                               literalTranslation: literal, distance: focused.distance), ms(start))
    }

    // The gaze point identifies a word. Keep the English context around small
    // non-English insertions, such as quoted Han examples inside English prose.
    // Replacing Han scalars with spaces preserves UTF-16 offsets for the anchor.
    let focusedRow = rows[focused.row]
    func preservingEnglish(_ text: String) -> String {
        var result = ""
        for scalar in excludingInlinePaths(text).unicodeScalars {
            if (0x3400...0x9FFF).contains(scalar.value) {
                result += String(repeating: " ", count: scalar.utf16.count)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
    // The focal token itself is Latin. A Chinese-heavy surrounding line should
    // reduce context, not suppress translation of that visible English token.
    var selected = [focused.row]
    func canJoin(_ first: Int, _ second: Int) -> Bool {
        let a = rows[first].box
        let b = rows[second].box
        guard !looksLikePathOrCode(rows[second].text),
              englishDominant(rows[first].text),
              englishDominant(rows[second].text),
              a.height > 0, b.height > 0 else { return false }
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
    } else {
        for index in selected {
            if !combined.isEmpty { combined += " " }
            if index == focused.row {
                anchorOffset = (combined as NSString).length + focused.range.location
            }
            combined += preservingEnglish(rows[index].text)
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
    if (words.count > 60 || sentence.count > 320),
       let focusIndex = words.firstIndex(where: {
           $0.range.location <= offset && offset < NSMaxRange($0.range)
       }) {
        let source = sentence as NSString
        var first = max(0, focusIndex - 20)
        var last = min(words.count - 1, focusIndex + 20)
        while first < last &&
              (NSMaxRange(words[last].range) - words[first].range.location) > 300 {
            if last - focusIndex >= focusIndex - first && last > focusIndex {
                last -= 1
            } else if first < focusIndex {
                first += 1
            } else {
                break
            }
        }
        let selected = NSRange(location: words[first].range.location,
                               length: NSMaxRange(words[last].range) -
                                   words[first].range.location)
        sentence = source.substring(with: selected)
        offset -= selected.location
        words = regex.matches(in: sentence,
                              range: NSRange(location: 0,
                                             length: (sentence as NSString).length))
    }
    guard (1...60).contains(words.count), sentence.count <= 320,
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
                           selectionFocusRowBox: selectionRow.map { rows[$0].box },
                           maskedSentence: masked, localContext: local,
                           maskedLocalContext: maskedLocal,
                           microContext: micro, maskedMicroContext: maskedMicro,
                           prefixContext: prefixContext,
                           maskedPrefixContext: maskedPrefix,
                           literalTranslation: nil,
                           distance: focused.distance), ms(start))
}

// Eye-shaped, click-through word translation experiment. The clear center is live desktop content.
// ⌃⌥L toggles the lens; Esc hides it. Optional: --fixed-point <x> <y> (AppKit coordinates).
import AppKit
import ApplicationServices
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

// Retained for the offline OCR comparison CLI; the live visual fallback uses
// ordinary OCR and compares it with accessibility selection text.
private func highContrastSelectionImage(_ image: CGImage) -> CGImage? {
    let width = image.width
    let height = image.height
    let rowBytes = width * 4
    var pixels = [UInt8](repeating: 0, count: rowBytes * height)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue |
        CGBitmapInfo.byteOrder32Big.rawValue
    guard let context = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: rowBytes,
                                  space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        let red = Int(pixels[offset])
        let green = Int(pixels[offset + 1])
        let blue = Int(pixels[offset + 2])
        let brightGlyph = min(red, green, blue) >= 175
        let value: UInt8 = brightGlyph ? 255 : 0
        pixels[offset] = value
        pixels[offset + 1] = value
        pixels[offset + 2] = value
        pixels[offset + 3] = 255
    }
    return context.makeImage()
}

private struct LiveSelection {
    let text: String?
    let state: String
    let pointHit: Bool
    let geometryAvailable: Bool
}

private enum SelectionGeometry { case hit, miss, unavailable }

private func axValue<T>(_ value: CFTypeRef?, type: AXValueType, into result: inout T) -> Bool {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return false }
    return withUnsafeMutableBytes(of: &result) {
        AXValueGetValue(value as! AXValue, type, $0.baseAddress!)
    }
}

private func axParameter(_ element: AXUIElement, _ name: String,
                         _ input: CFTypeRef) -> CFTypeRef? {
    var output: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString,
                                                      input, &output) == .success else { return nil }
    return output
}

private func axPoint(_ pointer: CGPoint) -> CGPoint {
    // Accessibility uses a top-left screen origin; AppKit uses bottom-left.
    let main = NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            == CGMainDisplayID()
    }
    return CGPoint(x: pointer.x, y: (main?.frame.maxY ?? 0) - pointer.y)
}

private func axRect(_ value: CFTypeRef?) -> CGRect? {
    var bounds = CGRect.zero
    guard axValue(value, type: .cgRect, into: &bounds),
          bounds.width > 0, bounds.height > 0,
          bounds.origin.x.isFinite, bounds.origin.y.isFinite else { return nil }
    return bounds
}

// Chromium can provide the selection's text markers and bounds while refusing
// AXTextMarkerForPosition. Walk its visual line ends instead of using the
// selection's union rectangle, which would include unselected gaps.
private func selectedMarkerLinesHit(_ element: AXUIElement, range: AXTextMarkerRange,
                                    point: CGPoint) -> SelectionGeometry {
    guard let union = axRect(axParameter(element, "AXBoundsForTextMarkerRange", range)) else {
        return .unavailable
    }
    guard union.insetBy(dx: -2, dy: -2).contains(point) else { return .miss }
    guard let source = axParameter(element, "AXStringForTextMarkerRange", range) as? String,
          !source.isEmpty else { return .unavailable }
    let totalLength = (source as NSString).length
    let end = AXTextMarkerRangeCopyEndMarker(range)
    var cursor = AXTextMarkerRangeCopyStartMarker(range)
    var consumed = 0
    for _ in 0..<80 {
        guard let next = axParameter(element, "AXNextLineEndTextMarkerForTextMarker", cursor),
              CFGetTypeID(next) == AXTextMarkerGetTypeID() else {
            // A single visual line has no internal gaps to distinguish.
            return consumed == 0 && union.height <= 42 ? .hit : .unavailable
        }
        let wholeLine = AXTextMarkerRangeCreate(nil, cursor, next as! AXTextMarker)
        guard let lineText = axParameter(element, "AXStringForTextMarkerRange", wholeLine) as? String,
              !lineText.isEmpty else { return .unavailable }
        let lineLength = (lineText as NSString).length
        let lastLine = consumed + lineLength >= totalLength
        let fragment = consumed + lineLength > totalLength ?
            AXTextMarkerRangeCreate(nil, cursor, end) : wholeLine
        if let bounds = axRect(axParameter(element, "AXBoundsForTextMarkerRange", fragment)) {
            if bounds.insetBy(dx: -2, dy: -2).contains(point) { return .hit }
        } else {
            return .unavailable
        }
        if lastLine { return .miss }
        consumed += lineLength
        cursor = next as! AXTextMarker
    }
    return .unavailable
}

private func selectedPointHit(_ element: AXUIElement, pointer: CGPoint,
                              markerRange: CFTypeRef?) -> SelectionGeometry {
    var point = axPoint(pointer)
    guard let position = AXValueCreate(.cgPoint, &point) else { return .unavailable }
    if let selectedValue = axParameter(element, "AXRangeForPosition", position) {
        var selected = CFRange()
        // Native text elements expose a selected CFRange. The position range
        // identifies the actual character under the pointer, not an OCR guess.
        var selectedAttribute: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                         &selectedAttribute) == .success,
           axValue(selectedAttribute, type: .cfRange, into: &selected),
           selected.length > 0 {
            var pointed = CFRange()
            if axValue(selectedValue, type: .cfRange, into: &pointed),
               pointed.length > 0 {
                var character = CFRange(location: pointed.location, length: 1)
                if let characterValue = AXValueCreate(.cfRange, &character),
                   let boundsValue = axParameter(element, "AXBoundsForRange", characterValue) {
                    var bounds = CGRect.zero
                    if axValue(boundsValue, type: .cgRect, into: &bounds),
                       bounds.width > 0, bounds.height > 0,
                       bounds.insetBy(dx: -3, dy: -3).contains(point) {
                        return pointed.location >= selected.location &&
                            pointed.location < selected.location + selected.length ? .hit : .miss
                    }
                }
            }
            // Chromium reports a dummy 0:0 range here. Try text-marker
            // geometry before declaring the visible selection a miss.
        }
    }
    guard let markerRange,
          CFGetTypeID(markerRange) == AXTextMarkerRangeGetTypeID() else { return .unavailable }
    let range = markerRange as! AXTextMarkerRange
    if let pointedMarker = axParameter(element, "AXTextMarkerForPosition", position),
       CFGetTypeID(pointedMarker) == AXTextMarkerGetTypeID() {
        let start = AXTextMarkerRangeCopyStartMarker(range)
        let end = AXTextMarkerRangeCopyEndMarker(range)
        if let pointedIndex = axParameter(element, "AXIndexForTextMarker", pointedMarker) as? NSNumber,
           let startIndex = axParameter(element, "AXIndexForTextMarker", start) as? NSNumber,
           let endIndex = axParameter(element, "AXIndexForTextMarker", end) as? NSNumber,
           pointedIndex.intValue >= startIndex.intValue,
           pointedIndex.intValue < endIndex.intValue,
           let next = axParameter(element, "AXTextMarkerForIndex",
                                  NSNumber(value: pointedIndex.intValue + 1)),
           CFGetTypeID(next) == AXTextMarkerGetTypeID() {
            let characterRange = AXTextMarkerRangeCreate(nil,
                pointedMarker as! AXTextMarker, next as! AXTextMarker)
            if let bounds = axRect(axParameter(element, "AXBoundsForTextMarkerRange", characterRange)),
               bounds.insetBy(dx: -3, dy: -3).contains(point) {
                return .hit
            }
        }
    }
    return selectedMarkerLinesHit(element, range: range, point: point)
}

private func selectionOnElement(_ element: AXUIElement,
                                pointer: CGPoint?) -> (LiveSelection, Int)? {
    AXUIElementSetMessagingTimeout(element, 0.2)
    var value: CFTypeRef?
    let selectionError = AXUIElementCopyAttributeValue(
        element, kAXSelectedTextAttribute as CFString, &value)
    var raw = selectionError == .success ? value as? String : nil
    var method = "selected-text"
    var markerRange: CFTypeRef?
    // Read the marker range even when AXSelectedText exists: some WebKit
    // elements provide its text but no native AXSelectedTextRange geometry.
    let rangeError = AXUIElementCopyAttributeValue(
        element, "AXSelectedTextMarkerRange" as CFString, &markerRange)
    if raw?.isEmpty != false, rangeError == .success, let markerRange {
        if CFGetTypeID(markerRange) == AXTextMarkerRangeGetTypeID() {
            var markedText: CFTypeRef?
            let markedError = AXUIElementCopyParameterizedAttributeValue(
                element, "AXStringForTextMarkerRange" as CFString,
                markerRange, &markedText)
            if markedError == .success {
                raw = markedText as? String
                method = "text-marker"
            }
        }
    }
    // Some Chromium accessibility trees expose the complete AXSelectedText but
    // marker indices and bounds for only the last paragraph. Curiously, asking
    // for the marker's string can still return the complete text. Verify both
    // its text and its index span before allowing marker geometry to veto OCR.
    if let raw, let rangeValue = markerRange,
       CFGetTypeID(rangeValue) == AXTextMarkerRangeGetTypeID() {
        let marked = axParameter(element, "AXStringForTextMarkerRange", rangeValue) as? String
        let range = rangeValue as! AXTextMarkerRange
        let start = AXTextMarkerRangeCopyStartMarker(range)
        let end = AXTextMarkerRangeCopyEndMarker(range)
        let startIndex = axParameter(element, "AXIndexForTextMarker", start) as? NSNumber
        let endIndex = axParameter(element, "AXIndexForTextMarker", end) as? NSNumber
        let spanMismatch: Bool
        if let startIndex, let endIndex {
            spanMismatch = endIndex.intValue - startIndex.intValue != (raw as NSString).length
        } else {
            spanMismatch = false
        }
        if marked != raw || spanMismatch { markerRange = nil }
    }
    guard let raw,
          !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    let text = eligibleEnglishText(raw, maxLength: 1200)
    let geometry = pointer.map {
        selectedPointHit(element, pointer: $0, markerRange: markerRange)
    } ?? .unavailable
    let result = LiveSelection(text: text, state: text == nil ? "ineligible" : method,
                               pointHit: geometry == .hit,
                               geometryAvailable: geometry != .unavailable)
    return (result, raw.count)
}

// Reading the highlighted text does not change the clipboard or the target app.
// Screen hit testing matters: the focused element can be a composer or toolbar
// while the actual selection belongs to a different web content element.
private func readLiveSelection(at pointer: CGPoint? = nil,
                               targetPID: pid_t? = nil) -> LiveSelection {
    let empty = LiveSelection(text: nil, state: "none", pointHit: false,
                              geometryAvailable: false)
    guard AXIsProcessTrusted() else {
        return LiveSelection(text: nil, state: "permission-denied", pointHit: false,
                             geometryAvailable: false)
    }
    guard let pid = targetPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier,
          pid != ProcessInfo.processInfo.processIdentifier else {
        return LiveSelection(text: nil, state: "no-target", pointHit: false,
                             geometryAvailable: false)
    }
    let application = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(application, 0.2)
    var focused: CFTypeRef?
    AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString,
                                  &focused)
    guard let pointer else {
        guard let focused else { return empty }
        return selectionOnElement(focused as! AXUIElement, pointer: nil)?.0 ?? empty
    }
    let point = axPoint(pointer)
    var best: (LiveSelection, Int)?
    var visualCandidate: (LiveSelection, Int)?
    func inspectAncestors(_ start: AXUIElement) {
        var element = start
        for _ in 0..<14 {
            if let candidate = selectionOnElement(element, pointer: pointer) {
                if candidate.0.pointHit, candidate.1 > (best?.1 ?? -1) {
                    best = candidate
                } else if !candidate.0.pointHit, candidate.0.text != nil,
                          candidate.1 > (visualCandidate?.1 ?? -1) {
                    visualCandidate = candidate
                }
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString,
                                                &parent) == .success,
                  let parent else { break }
            element = parent as! AXUIElement
        }
    }
    var hit: AXUIElement?
    if AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y),
                                        &hit) == .success, let hit {
        inspectAncestors(hit)
    }
    // Some Chromium shells hit-test their application root as the menu bar.
    // The system-wide hit can expose the actual web text; accept it only when
    // the returned element belongs to the same foreground process.
    if best == nil {
        let system = AXUIElementCreateSystemWide()
        var globalHit: AXUIElement?
        if AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y),
                                            &globalHit) == .success, let globalHit {
            var owner: pid_t = 0
            if AXUIElementGetPid(globalHit, &owner) == .success, owner == pid {
                inspectAncestors(globalHit)
            }
        }
    }
    if let best { return best.0 }
    if let focused,
       let fallback = selectionOnElement(focused as! AXUIElement, pointer: pointer) {
        if fallback.0.pointHit { return fallback.0 }
        if fallback.0.text != nil,
           fallback.1 > (visualCandidate?.1 ?? -1) {
            visualCandidate = fallback
        }
    }
    // Geometry from embedded web views can report a miss even while the
    // selection is visibly under the pointer. Keep the text as a candidate;
    // the captured frame decides whether it is actually highlighted here.
    if let visualCandidate { return visualCandidate.0 }
    return empty
}

private struct FocusedPassage {
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

private let focusMarker = "⟦X⟧"
private let relativeTimeRegex = try! NSRegularExpression(
    pattern: "\\b([0-9]+)?\\s*(seconds?|minutes?|hours?|days?|weeks?|months?|years?)\\s*ago\\b",
    options: [.caseInsensitive])
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

private func translationFallback(_ text: String?, maxLength: Int) -> String? {
    guard let text else { return nil }
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count <= maxLength,
          value.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }),
          !value.contains(focusMarker) else { return nil }
    return value
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

private func englishDominant(_ text: String) -> Bool {
    let latin = text.unicodeScalars.filter {
        (65...90).contains($0.value) || (97...122).contains($0.value)
    }.count
    let han = text.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) }.count
    return han == 0 ? latin > 0 : latin >= max(12, han * 3)
}

private func eligibleEnglishText(_ raw: String, maxLength: Int) -> String? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (2...maxLength).contains(text.count),
          text.range(of: "[A-Za-z]", options: .regularExpression) != nil,
          !looksLikePathOrCode(text), !text.contains("{") && !text.contains("}") else {
        return nil
    }
    if text.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) {
        // English prose may quote Chinese examples. Keep its full selection,
        // while a Chinese passage with a stray Latin abbreviation stays out.
        guard clipboardWords(text).count >= 3,
              englishDominant(text) else { return nil }
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

private func eligibleClipboardHint(_ raw: String) -> String? {
    eligibleEnglishText(raw, maxLength: 400)
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

private func foldedLetters(_ text: String) -> [Character] {
    Array(text.lowercased().filter { $0.isASCII && $0.isLetter })
}

private func oneEditCost(_ first: [Character], _ second: [Character]) -> Int? {
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

private func selectedTextAtFocus(_ hint: String, anchor: String,
                                 focusLine: String, focusWordIndex: Int,
                                 allowShortOCRNoise: Bool = false,
                                 minimumVerifiedWords: Int = 2,
                                 minimumVerifiedLetters: Int = 0,
                                 windowRadius: Int = 2) -> String? {
    guard hint.count <= 1200 else { return nil }
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

private func selectionHighlightAtCenter(_ image: CGImage, focus: CGPoint,
                                        row: CGRect?) -> Bool {
    guard let row else { return false }
    let bitmap = NSBitmapImageRep(cgImage: image)
    let width = bitmap.pixelsWide
    let height = bitmap.pixelsHigh
    let x = Int(focus.x * CGFloat(width))
    let y = Int((1 - focus.y) * CGFloat(height))
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
    guard let center = dominant(x, y), center.1 >= 30 else { return false }
    let left = Int(row.minX * CGFloat(width)) - 14
    let right = Int(row.maxX * CGFloat(width)) + 14
    let above = Int((1 - row.maxY) * CGFloat(height)) - 14
    let below = Int((1 - row.minY) * CGFloat(height)) + 14
    let references = [dominant(left, y), dominant(right, y),
                      dominant(x, above), dominant(x, below)].compactMap { $0 }
    func colorDistance(_ a: Int, _ b: Int) -> Int {
        abs(((a >> 16) & 255) - ((b >> 16) & 255)) +
        abs(((a >> 8) & 255) - ((b >> 8) & 255)) +
        abs((a & 255) - (b & 255))
    }
    func chroma(_ color: Int) -> Int {
        let channels = [(color >> 16) & 255, (color >> 8) & 255, color & 255]
        return (channels.max() ?? 0) - (channels.min() ?? 0)
    }
    // A dark unselected row can differ greatly from the blue selection on
    // the row beside it. The center itself must carry the tinted fill.
    return chroma(center.0) >= 25 && references.contains {
        colorDistance(center.0, $0.0) >= 80 &&
            chroma(center.0) - chroma($0.0) >= 15
    }
}

private func visuallyConfirmedSelection(_ live: LiveSelection,
                                        passage: FocusedPassage?,
                                        image: CGImage, focus: CGPoint) -> Bool {
    guard live.text != nil, let passage else { return false }
    return selectionHighlightAtCenter(image, focus: focus,
                                      row: passage.selectionFocusRowBox)
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
    if ordinary?.caseInsensitiveCompare(raw) != .orderedSame,
       let hinted = hintedOCRCorrection(raw, hint: hint) {
        return (hinted, true)
    }
    // Vision already located a Latin token under the gaze. Spell checking may
    // reject names, inflections, or noisy OCR; keep that token as a low-confidence
    // focus instead of silently switching to a neighboring word.
    return (ordinary ?? (raw.count >= 2 ? raw : nil), false)
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
        for scalar in text.unicodeScalars {
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
                           selectionFocusRowBox: selectionRow.map { rows[$0].box },
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
            let start = uptime()
            do {
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
                // One malformed contextual request must not suppress a readable
                // focal word. Retry only that word on the same local session.
                do {
                    let response = try await session.translations(from: [
                        TranslationSession.Request(sourceText: anchor,
                                                   clientIdentifier: "word")
                    ])
                    let direct = response.first?.targetText
                    let fallback = resolveFocus(anchor: anchor, full: "", masked: "",
                                                local: "", maskedLocal: "",
                                                sourceLocal: localContext,
                                                sourceMicro: microContext,
                                                micro: "", maskedMicro: "",
                                                sourcePrefix: prefixContext,
                                                prefix: "", maskedPrefix: "",
                                                direct: direct)
                    bridge.onResult?(generation, .success((fallback, ms(start))))
                } catch {
                    bridge.onResult?(generation, .failure(error))
                }
            }
        }
    }
}

@MainActor
private final class EyeLensView: NSView {
    var isReading = false { didSet { needsDisplay = true } }
    var hasTranslation = false { didSet { needsDisplay = true } }

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
                ? NSColor(calibratedWhite: 0.80, alpha: 0.13)
                : NSColor(calibratedWhite: 0.96, alpha: 0.07)
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
        pupilEdge.lineWidth = hasTranslation ? 1.2 : 0.8
        if hasTranslation {
            NSColor.systemYellow.withAlphaComponent(0.72).setStroke()
        } else {
            NSColor(calibratedWhite: 0.92, alpha: 0.28).setStroke()
        }
        pupilEdge.stroke()
        let eyeBallDiameter = pupil.height * 0.56
        let eyeBallRadius = eyeBallDiameter / 2
        let eyeBallRect = CGRect(x: center.x - eyeBallRadius, y: center.y - eyeBallRadius,
                                 width: eyeBallDiameter, height: eyeBallDiameter)
        let eyeBall = NSBezierPath(ovalIn: eyeBallRect)
        // Fine, uneven iris fibers leave the central sight line open for the source text.
        context.saveGState()
        eyeBall.addClip()
        context.setLineCap(.round)
        for index in 0..<64 {
            let phase = CGFloat(index)
            let angle = phase * 2 * .pi / 64 + 0.035 * sin(phase * 2.37)
            let innerRadius = eyeBallRadius * (0.32 + 0.06 * sin(phase * 1.73))
            let outerRadius = eyeBallRadius * (0.78 + 0.16 * sin(phase * 0.91))
            let bend = angle + 0.09 * sin(phase * 1.19)
            context.setStrokeColor(NSColor(calibratedRed: 0.66, green: 0.77, blue: 0.84,
                                           alpha: index.isMultiple(of: 5) ? 0.19 : 0.10).cgColor)
            context.setLineWidth(index.isMultiple(of: 7) ? 0.7 : 0.45)
            context.move(to: CGPoint(x: center.x + cos(angle) * innerRadius,
                                     y: center.y + sin(angle) * innerRadius))
            context.addQuadCurve(to: CGPoint(x: center.x + cos(angle) * outerRadius,
                                             y: center.y + sin(angle) * outerRadius),
                                 control: CGPoint(x: center.x + cos(bend) * eyeBallRadius * 0.60,
                                                  y: center.y + sin(bend) * eyeBallRadius * 0.60))
            context.strokePath()
        }
        context.restoreGState()
        let innerEye = NSBezierPath(ovalIn: eyeBallRect.insetBy(dx: eyeBallRadius * 0.73,
                                                                 dy: eyeBallRadius * 0.73))
        innerEye.lineWidth = 0.55
        NSColor(calibratedWhite: 0.95, alpha: 0.16).setStroke()
        innerEye.stroke()
        eyeBall.lineWidth = 0.7
        NSColor(calibratedWhite: 0.96, alpha: 0.16).setStroke()
        eyeBall.stroke()
        let lowerLid = NSBezierPath()
        lowerLid.move(to: CGPoint(x: center.x + irisRadiusX * 0.38,
                                  y: center.y - irisRadiusY * 0.70))
        lowerLid.curve(to: CGPoint(x: center.x + irisRadiusX * 0.86,
                                   y: center.y - irisRadiusY * 0.22),
                       controlPoint1: CGPoint(x: center.x + irisRadiusX * 0.56,
                                              y: center.y - irisRadiusY * 0.64),
                       controlPoint2: CGPoint(x: center.x + irisRadiusX * 0.75,
                                              y: center.y - irisRadiusY * 0.39))
        lowerLid.lineWidth = 0.75
        NSColor(calibratedWhite: 0.96, alpha: 0.22).setStroke()
        lowerLid.stroke()
        let upperLid = NSBezierPath()
        upperLid.move(to: CGPoint(x: center.x - irisRadiusX * 0.38,
                                  y: center.y + irisRadiusY * 0.70))
        upperLid.curve(to: CGPoint(x: center.x - irisRadiusX * 0.86,
                                   y: center.y + irisRadiusY * 0.22),
                       controlPoint1: CGPoint(x: center.x - irisRadiusX * 0.56,
                                              y: center.y + irisRadiusY * 0.64),
                       controlPoint2: CGPoint(x: center.x - irisRadiusX * 0.75,
                                              y: center.y + irisRadiusY * 0.39))
        upperLid.lineWidth = 0.75
        NSColor(calibratedWhite: 0.96, alpha: 0.22).setStroke()
        upperLid.stroke()
        // Fine folds shorten evenly toward the right tip, clear of the lower accent.
        context.saveGState()
        eye.addClip()
        for index in 0..<8 {
            let progress = CGFloat(index) / 7
            let lastFold = index == 7
            let end = CGPoint(x: eyeRect.maxX - CGFloat(index) - (lastFold ? 2 : 0),
                              y: eyeRect.midY + 2 - 0.7 * CGFloat(index))
            let start = CGPoint(x: center.x + irisRadiusX * (0.48 + 0.47 * progress),
                                y: lastFold ? end.y + 0.8
                                    : center.y + irisRadiusY * (0.74 - 0.90 * progress))
            let dx = end.x - start.x
            let dy = start.y - end.y
            let line = NSBezierPath()
            line.move(to: start)
            line.curve(to: end,
                       controlPoint1: CGPoint(x: start.x + dx * 0.32, y: start.y - dy * 0.08),
                       controlPoint2: CGPoint(x: end.x - dx * 0.22, y: end.y + dy * 0.23))
            line.lineWidth = lastFold ? 0.5 : 0.62
            line.lineCapStyle = .round
            let alpha = lastFold ? 0.06 : 0.22 - 0.013 * CGFloat(index)
            NSColor(calibratedWhite: 0.96, alpha: alpha).setStroke()
            line.stroke()
        }
        context.restoreGState()
        // The outer contour stays decorative; lock-on is shown at the clear center.
        eye.lineWidth = 1.8
        NSColor(calibratedWhite: 0.02, alpha: 0.02).setStroke()
        eye.stroke()
        eye.lineWidth = 0.8
        NSColor(calibratedWhite: 0.96, alpha: 0.02).setStroke()
        eye.stroke()
        let lampCenter = CGPoint(x: eyeRect.minX + 13,
                                 y: eyeRect.midY - 2)
        let breath = (1 + sin(uptime() * .pi * 2 / 2.2)) / 2
        NSColor.systemRed.withAlphaComponent(0.10 + 0.17 * breath).setFill()
        NSBezierPath(ovalIn: CGRect(x: lampCenter.x - 7, y: lampCenter.y - 7,
                                    width: 14, height: 14)).fill()
        NSColor.systemRed.withAlphaComponent(0.58 + 0.35 * breath).setFill()
        NSBezierPath(ovalIn: CGRect(x: lampCenter.x - 2.5, y: lampCenter.y - 2.5,
                                    width: 5, height: 5)).fill()
    }
}

@MainActor
private final class WordMagnifierProbe: NSObject, NSApplicationDelegate {
    private let lensSize = CGSize(width: 190, height: 114)
    private let bridge = WordTranslationBridge()
    private let selectionBridge = SelectionTranslationBridge()
    private var panel: NSPanel!
    private var translationPanel: NSPanel!
    private var contextLabel: NSTextField!
    private var wordLabel: NSTextField!
    private var view: EyeLensView!
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var nextBreathFrameAt = 0.0
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
    private var activeSelectionHint: String?
    private var activeSelectionSource = "none"
    private var selectionHitGeneration = -1
    private var selectionHitPointer = CGPoint.zero
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
        frost.alphaValue = 0.58
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
        card.layer?.borderWidth = 0.8
        card.layer?.borderColor = NSColor(calibratedWhite: 0.9, alpha: 0.18).cgColor
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
        activeSelectionHint = nil
        activeSelectionSource = "none"
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
        view.hasTranslation = false
        nextBreathFrameAt = 0
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
        view.hasTranslation = false
        releaseEscape()
        currentSentence = nil
        currentAnchor = nil
        currentFocusLine = nil
        currentFocusWordIndex = nil
        pendingTranslationKey = nil
        clipboardHint = nil
        clipboardHintMisses = 0
        activeSelectionHint = nil
        activeSelectionSource = "none"
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
        clipboardHint = pasteboard.string(forType: .string).flatMap(eligibleClipboardHint)
        clipboardHintDeadline = uptime() + 5
        clipboardHintMisses = 0
        if !activeSelectionSource.hasPrefix("accessibility") {
            selectionRequestID += 1
            pendingSelectionText = nil
            showingSelectionCard = false
            generation += 1
            inspectedGeneration = -1
            nextInspectionAt = 0
            pendingTranslationKey = nil
            translationPanel.orderOut(nil)
        }
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
        if !activeSelectionSource.hasPrefix("accessibility") {
            selectionRequestID += 1
            pendingSelectionText = nil
            if showingSelectionCard {
                translationPanel.orderOut(nil)
                showingSelectionCard = false
            }
        }
        print("CLIPBOARD_HINT ended reason=\(reason)")
        fflush(stdout)
    }

    private func showFocusCard(_ chinese: String, anchor: String, basis: String,
                               pointer: CGPoint) {
        guard let screen = screen(at: pointer) else { return }
        showingSelectionCard = false
        let width: CGFloat = min(min(420, screen.frame.width - 12),
            max(180, CGFloat(max(anchor.count + basis.count, chinese.count)) * 15 + 36))
        let contentWidth = width - 32
        let font = NSFont.systemFont(ofSize: 16, weight: .medium)
        let measured = (chinese as NSString).boundingRect(
            with: CGSize(width: contentWidth, height: 10000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]).height
        contextLabel.font = font
        contextLabel.stringValue = chinese
        let cellHeight = contextLabel.cell?.cellSize(
            forBounds: CGRect(x: 0, y: 0, width: contentWidth, height: 10000)).height ?? 0
        let textHeight = min(screen.frame.height - 120,
                             max(30, ceil(max(measured, cellHeight)) + 12))
        let height = textHeight + 44
        translationPanel.setContentSize(CGSize(width: width, height: height))
        translationPanel.contentView?.frame = CGRect(x: 0, y: 0, width: width, height: height)
        wordLabel.stringValue = "\(anchor) · \(basis)"
        wordLabel.frame = CGRect(x: 16, y: height - 30, width: contentWidth, height: 18)
        contextLabel.frame = CGRect(x: 16, y: 10, width: contentWidth, height: textHeight)
        let eyeFrame = panel.frame
        let x = max(screen.frame.minX + 6,
                    min(eyeFrame.midX - width / 2, screen.frame.maxX - width - 6))
        let below = eyeFrame.minY - height - 8
        let y = below >= screen.frame.minY + 6 ? below :
            min(eyeFrame.maxY + 8, screen.frame.maxY - height - 6)
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
            with: CGSize(width: contentWidth, height: 10000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]).height
        contextLabel.font = font
        contextLabel.stringValue = chinese
        let cellHeight = contextLabel.cell?.cellSize(
            forBounds: CGRect(x: 0, y: 0, width: contentWidth, height: 10000)).height ?? 0
        // NSTextField wraps Chinese text differently from NSString's estimate.
        // Leave another line of room so the translated tail remains visible.
        let textHeight = min(screen.frame.height - 120,
                             max(34, ceil(max(measured, cellHeight)) + 22))
        let height = textHeight + 54
        translationPanel.setContentSize(CGSize(width: width, height: height))
        translationPanel.contentView?.frame = CGRect(x: 0, y: 0, width: width, height: height)
        wordLabel.stringValue = "选区翻译"
        wordLabel.frame = CGRect(x: 16, y: height - 34, width: contentWidth, height: 18)
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
            let pointer = fixedPoint ?? NSEvent.mouseLocation
            let stillSelected: Bool
            if activeSelectionSource == "accessibility" {
                let live = readLiveSelection(at: pointer)
                stillSelected = live.pointHit && live.text == source
            } else {
                // The pixel hit was checked in the same pointer generation.
                // Movement or a changed AX selection invalidates it; the next
                // scan can use the cache after checking the visible frame.
                let live = readLiveSelection(at: pointer)
                stillSelected = activeSelectionSource == "accessibility-visual" &&
                    selectionHitGeneration == generation && live.text == source &&
                    hypot(pointer.x - selectionHitPointer.x,
                          pointer.y - selectionHitPointer.y) < 3
            }
            if panel.isVisible, activeSelectionHint == source,
               stillSelected {
                showSelectionCard(translated, pointer: fixedPoint ?? NSEvent.mouseLocation)
            }
            print(String(format: "SELECTION_TRANSLATION translatedMs=%.1f resolved=yes sourceLength=%d targetLength=%d cloudCalls=0",
                         elapsed, source.count, translated.count))
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

    // Once the center is verified against the live selection, use its complete
    // AX text. The visual fallback verifies location before calling this.
    private func handleSelectedPointHit(_ live: LiveSelection, pointer: CGPoint,
                                        generation current: Int,
                                        sourceName: String = "accessibility") -> Bool {
        guard panel.isVisible, current == generation, live.pointHit else { return false }
        selectionHitGeneration = current
        selectionHitPointer = pointer
        let selected = live.text
        if activeSelectionHint != selected || activeSelectionSource != sourceName {
            selectionRequestID += 1
            pendingSelectionText = nil
            activeSelectionHint = selected
            activeSelectionSource = sourceName
            print("SELECTION_HIT source=\(sourceName) length=\(selected?.count ?? 0) axState=\(live.state)")
        }
        currentSentence = nil
        currentAnchor = nil
        currentFocusLine = nil
        currentFocusWordIndex = nil
        pendingTranslationKey = nil
        view.isReading = false
        inspectedGeneration = -1
        nextInspectionAt = uptime() + (sourceName == "accessibility-visual" ? 0.6 : 0.3)
        if let selected, let cached = selectionCache[selected] {
            showSelectionCard(cached, pointer: pointer)
        } else if let selected, pendingSelectionText != selected {
            translationPanel.orderOut(nil)
            showingSelectionCard = false
            selectionRequestID += 1
            pendingSelectionText = selected
            selectionBridge.translate(selected, requestID: selectionRequestID)
            print("SELECTION_TRANSLATION requested length=\(selected.count) cloudCalls=0")
        } else if selected == nil {
            translationPanel.orderOut(nil)
            showingSelectionCard = false
        }
        fflush(stdout)
        return true
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
            let affectsFocus = !activeSelectionSource.hasPrefix("accessibility")
            endClipboardHint(reason: "expired")
            if affectsFocus {
                generation += 1
                inspectedGeneration = -1
                nextInspectionAt = 0
                pendingTranslationKey = nil
            }
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
        let now = uptime()
        let success = now - lastMoveAt >= 0.10 && translationPanel.isVisible &&
            translationPanel.alphaValue > 0.5 &&
            (showingSelectionCard || currentAnchor != nil)
        if view.hasTranslation != success { view.hasTranslation = success }
        if now >= nextBreathFrameAt {
            view.needsDisplay = true
            nextBreathFrameAt = now + 1.0 / 24.0
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
            // Diagnostic switch exercises the pixel path on apps with reliable
            // AX hit geometry; normal launches keep the fast AX path.
            func visualOnly(_ selection: LiveSelection) -> LiveSelection {
                guard CommandLine.arguments.contains("--force-visual-selection") else {
                    return selection
                }
                return LiveSelection(text: selection.text, state: selection.state,
                                     pointHit: false, geometryAvailable: false)
            }
            let initialSelection = visualOnly(readLiveSelection(at: pointer))
            if handleSelectedPointHit(initialSelection, pointer: pointer, generation: current) {
                return
            }
            if activeSelectionSource == "accessibility" {
                activeSelectionHint = nil
                activeSelectionSource = "none"
                selectionRequestID += 1
                pendingSelectionText = nil
                if showingSelectionCard {
                    translationPanel.orderOut(nil)
                    showingSelectionCard = false
                }
                print("SELECTION_HIT source=accessibility geometry=no")
            }
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
                return try passageAtCenter(scanImage, focus: focus, clipboardHint: hint)
            }.value
            guard panel.isVisible, current == generation else { return }
            let live = visualOnly(readLiveSelection(at: pointer))
            if handleSelectedPointHit(live, pointer: pointer, generation: current) { return }
            let candidate = live.text == nil ? initialSelection : live
            if visuallyConfirmedSelection(candidate, passage: passage,
                                          image: scanImage, focus: focus) {
                let visual = LiveSelection(text: candidate.text, state: candidate.state,
                                           pointHit: true, geometryAvailable: false)
                if handleSelectedPointHit(visual, pointer: pointer, generation: current,
                                          sourceName: "accessibility-visual") { return }
            }
            let source = "none"
            let selectionHint: String? = nil
            if activeSelectionHint != selectionHint || activeSelectionSource != source {
                selectionRequestID += 1
                pendingSelectionText = nil
                activeSelectionHint = selectionHint
                activeSelectionSource = source
                print("SELECTION_SOURCE source=\(source) axState=\(live.state) length=\(selectionHint?.count ?? 0)")
                fflush(stdout)
            }
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
        if activeSelectionSource != "none" ||
           readLiveSelection(at: fixedPoint ?? NSEvent.mouseLocation).pointHit { return }
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
        if args.contains("--inspect-ax-selection") {
            let selection = readLiveSelection()
            print("AX_SELECTION state=\(selection.state) length=\(selection.text?.count ?? 0)")
            return
        }
        if let index = args.firstIndex(of: "--inspect-selection-point"),
           index + 2 < args.count,
           let x = Double(args[index + 1]), let y = Double(args[index + 2]) {
            let pid = args.firstIndex(of: "--target-pid").flatMap {
                $0 + 1 < args.count ? pid_t(args[$0 + 1]) : nil
            }
            let selection = readLiveSelection(at: CGPoint(x: x, y: y), targetPID: pid)
            print("AX_SELECTION_POINT state=\(selection.state) length=\(selection.text?.count ?? 0) hit=\(selection.pointHit)")
            return
        }
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
                                    focusWordIndex: wordIndex,
                                    allowShortOCRNoise: args.contains("--trusted-selection"))
            }
            print("SELECTION_FOCUS_INSPECTION promotes=\(selected != nil)")
            return
        }
        if let index = args.firstIndex(of: "--inspect-selection-image"),
           index + 3 < args.count,
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
                let focus = CGPoint(x: (x - area.minX) / area.width,
                                    y: 1 - (y - area.minY) / area.height)
                let pointer = CGPoint(x: x / 2, y: (Double(image.height) - y) / 2)
                let pid = args.firstIndex(of: "--target-pid").flatMap {
                    $0 + 1 < args.count ? pid_t(args[$0 + 1]) : nil
                }
                let live: LiveSelection
                if let fixture = args.firstIndex(of: "--selection-text-file"),
                   fixture + 1 < args.count,
                   let text = try? String(contentsOfFile: args[fixture + 1],
                                          encoding: .utf8) {
                    live = LiveSelection(text: text, state: "fixture", pointHit: false,
                                         geometryAvailable: false)
                } else {
                    live = readLiveSelection(at: pointer, targetPID: pid)
                }
                do {
                    let (passage, _) = try passageAtCenter(cropped, focus: focus,
                        debug: args.contains("--show-ocr"))
                    let highlight = selectionHighlightAtCenter(cropped, focus: focus,
                        row: passage?.selectionFocusRowBox)
                    print("SELECTION_IMAGE axState=\(live.state) length=\(live.text?.count ?? 0) geometry=\(live.geometryAvailable) anchor=\(passage?.anchor ?? "none") focusIndex=\(passage?.focusWordIndex ?? -1) distance=\(passage?.distance ?? -1) highlight=\(highlight) matched=\(visuallyConfirmedSelection(live, passage: passage, image: cropped, focus: focus))")
                } catch { print("SELECTION_IMAGE_ERROR=\(error)") }
            }
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
                    let processed = args.contains("--selection-contrast") ?
                        highContrastSelectionImage(cropped) ?? cropped : cropped
                    let (passage, ocrMs) = try passageAtCenter(
                        processed, focus: focus, debug: args.contains("--show-ocr"),
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

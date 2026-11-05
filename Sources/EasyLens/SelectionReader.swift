// Migrated from the validated macOS lens prototype.
import AppKit
import ApplicationServices

func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
func ms(_ start: Double) -> Double { (uptime() - start) * 1_000 }

// Retained for the offline OCR comparison CLI; the live visual fallback uses
// ordinary OCR and compares it with accessibility selection text.
func highContrastSelectionImage(_ image: CGImage) -> CGImage? {
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

struct LiveSelection {
    let text: String?
    let state: String
    let pointHit: Bool
    let geometryAvailable: Bool
}

enum SelectionGeometry { case hit, miss, unavailable }

func axValue<T>(_ value: CFTypeRef?, type: AXValueType, into result: inout T) -> Bool {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return false }
    return withUnsafeMutableBytes(of: &result) {
        AXValueGetValue(value as! AXValue, type, $0.baseAddress!)
    }
}

func axParameter(_ element: AXUIElement, _ name: String,
                         _ input: CFTypeRef) -> CFTypeRef? {
    var output: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString,
                                                      input, &output) == .success else { return nil }
    return output
}

func axPoint(_ pointer: CGPoint) -> CGPoint {
    // Accessibility uses a top-left screen origin; AppKit uses bottom-left.
    let main = NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            == CGMainDisplayID()
    }
    return CGPoint(x: pointer.x, y: (main?.frame.maxY ?? 0) - pointer.y)
}

func axRect(_ value: CFTypeRef?) -> CGRect? {
    var bounds = CGRect.zero
    guard axValue(value, type: .cgRect, into: &bounds),
          bounds.width > 0, bounds.height > 0,
          bounds.origin.x.isFinite, bounds.origin.y.isFinite else { return nil }
    return bounds
}

// Chromium can provide the selection's text markers and bounds while refusing
// AXTextMarkerForPosition. Walk its visual line ends instead of using the
// selection's union rectangle, which would include unselected gaps.
func selectedMarkerLinesHit(_ element: AXUIElement, range: AXTextMarkerRange,
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

func selectedPointHit(_ element: AXUIElement, pointer: CGPoint,
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

private let explicitBlockAXRoles: Set<String> = [
    "AXHeading", "AXList", "AXListItem", "AXTable", "AXRow", "AXCell",
    "AXBlockQuote", "AXParagraph", "AXPre", "AXWebArea", "AXScrollArea",
    "AXSplitGroup", "AXOutline"
]

private let nonTextControlAXRoles: Set<String> = [
    "AXImage", "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle",
    "AXToolbar", "AXMenuBar", "AXMenu", "AXTabGroup"
]

private final class StructuredSelectionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entry: (raw: String, structured: String)?

    func get(for raw: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entry?.raw == raw ? entry?.structured : nil
    }

    func set(raw: String, structured: String) {
        lock.lock()
        defer { lock.unlock() }
        entry = (raw, structured)
    }
}

private let structuredSelectionCache = StructuredSelectionCache()

private func cleanSelectionFragment(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{FFFC}", with: "")
        .replacingOccurrences(of: "\u{00A0}", with: " ")
}

func matchSelectionInBlocks(raw: String, blocks: [String]) -> String? {
    let trimmedRaw = cleanSelectionFragment(raw)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanedBlocks = blocks
        .map { cleanSelectionFragment($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard !trimmedRaw.isEmpty, cleanedBlocks.count > 1 else { return nil }

    // 1. Fast path: exact substring match against concatenated blocks.
    var concatenated = ""
    var ranges: [(range: NSRange, block: String)] = []
    var offset = 0
    for block in cleanedBlocks {
        let len = (block as NSString).length
        ranges.append((NSRange(location: offset, length: len), block))
        concatenated += block
        offset += len
    }
    let fullNS = concatenated as NSString
    let matchRange = fullNS.range(of: trimmedRaw)
    if matchRange.location != NSNotFound, matchRange.length > 0 {
        let matchStart = matchRange.location
        let matchEnd = matchRange.location + matchRange.length
        var selectedParagraphs: [String] = []
        for (blockRange, block) in ranges {
            let blockStart = blockRange.location
            let blockEnd = blockRange.location + blockRange.length
            guard blockEnd > matchStart && blockStart < matchEnd else { continue }
            let sliceStart = max(0, matchStart - blockStart)
            let sliceEnd = min(blockRange.length, matchEnd - blockStart)
            guard sliceEnd > sliceStart else { continue }
            let nsBlock = block as NSString
            var slice = nsBlock.substring(with: NSRange(location: sliceStart, length: sliceEnd - sliceStart))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if sliceStart > 0 && sliceStart <= 3 {
                let prefix = nsBlock.substring(to: sliceStart).trimmingCharacters(in: .whitespaces)
                if prefix == "•" || prefix == "◦" || prefix == "▪" {
                    slice = "\(prefix) \(slice)"
                }
            }
            if !slice.isEmpty {
                selectedParagraphs.append(slice)
            }
        }
        if selectedParagraphs.count > 1 {
            return selectedParagraphs.joined(separator: "\n")
        }
    }

    // 2. Boundary-junction projection: even if a block contains an inline button/icon
    // (like "(?)") or slight whitespace differences in the middle, the boundary between
    // block[i] (its trailing suffix) and block[i+1] (its leading prefix) can be located
    // directly inside trimmedRaw to restore paragraph breaks accurately.
    let rawNS = trimmedRaw as NSString
    var splitOffsets: [(splitAt: Int, insertBullet: String?)] = []
    var searchStart = 0

    func stripLeadingBullet(_ text: String) -> (bullet: String?, body: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for marker in ["•", "◦", "▪"] where trimmed.hasPrefix(marker) {
            let rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            return (marker, rest)
        }
        return (nil, trimmed)
    }

    for i in 0..<(cleanedBlocks.count - 1) {
        let leftBlock = cleanedBlocks[i]
        let rightBlock = cleanedBlocks[i + 1]
        let leftNS = leftBlock as NSString
        let (rightBullet, rightBody) = stripLeadingBullet(rightBlock)
        let rightBodyNS = rightBody as NSString
        guard leftNS.length >= 4, rightBodyNS.length >= 4,
              searchStart < rawNS.length else { continue }

        var matchedSplit: (splitAt: Int, insertBullet: String?)?
        for suffixLen in [min(28, leftNS.length), min(16, leftNS.length), min(8, leftNS.length)] where suffixLen >= 4 {
            let suffix = leftNS.substring(from: leftNS.length - suffixLen)
                .trimmingCharacters(in: .whitespaces)
            guard suffix.count >= 4 else { continue }
            for prefixLen in [min(28, rightBodyNS.length), min(16, rightBodyNS.length), min(8, rightBodyNS.length)] where prefixLen >= 4 {
                let prefix = rightBodyNS.substring(to: prefixLen)
                    .trimmingCharacters(in: .whitespaces)
                guard prefix.count >= 4 else { continue }
                let escapedSuffix = NSRegularExpression.escapedPattern(for: suffix)
                let escapedPrefix = NSRegularExpression.escapedPattern(for: prefix)
                let pattern = "\(escapedSuffix)\\s*([•◦▪]\\s*)?\(escapedPrefix)"
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let searchRange = NSRange(location: searchStart, length: rawNS.length - searchStart)
                if let match = regex.firstMatch(in: trimmedRaw, range: searchRange) {
                    let suffixEnd = match.range.location + (suffix as NSString).length
                    let hasInlineBullet = match.range(at: 1).location != NSNotFound && match.range(at: 1).length > 0
                    let bulletToInsert = (!hasInlineBullet && rightBullet != nil) ? rightBullet : nil
                    matchedSplit = (suffixEnd, bulletToInsert)
                    break
                }
            }
            if matchedSplit != nil { break }
        }

        if let matchedSplit, matchedSplit.splitAt > searchStart, matchedSplit.splitAt < rawNS.length {
            splitOffsets.append(matchedSplit)
            searchStart = matchedSplit.splitAt
        }
    }

    guard !splitOffsets.isEmpty else { return nil }
    var paragraphs: [String] = []
    var cursor = 0
    for ( index, split) in splitOffsets.enumerated() {
        guard split.splitAt > cursor else { continue }
        var segment = rawNS.substring(with: NSRange(location: cursor, length: split.splitAt - cursor))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if index > 0, let prevBullet = splitOffsets[index - 1].insertBullet,
           !segment.hasPrefix("•") && !segment.hasPrefix("◦") && !segment.hasPrefix("▪") {
            segment = "\(prevBullet) \(segment)"
        }
        if !segment.isEmpty {
            paragraphs.append(segment)
        }
        cursor = split.splitAt
    }
    if cursor < rawNS.length {
        var tail = rawNS.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
        if let lastBullet = splitOffsets.last?.insertBullet,
           !tail.hasPrefix("•") && !tail.hasPrefix("◦") && !tail.hasPrefix("▪") {
            tail = "\(lastBullet) \(tail)"
        }
        if !tail.isEmpty {
            paragraphs.append(tail)
        }
    }
    guard paragraphs.count > 1 else { return nil }
    return paragraphs.joined(separator: "\n")
}

private func collectAXBlocks(from container: AXUIElement,
                             pivotChain: [AXUIElement] = [],
                             maxNodes: Int = 2500) -> [String] {
    var blocks: [String] = []
    var currentBlock = ""
    var visited = 0

    func flushBlock() {
        let trimmed = currentBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            blocks.append(trimmed)
        }
        currentBlock = ""
    }

    func roleOf(_ element: AXUIElement) -> String {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        return (roleRef as? String) ?? ""
    }

    func walk(_ node: AXUIElement, depth: Int, inParagraph: Bool) {
        guard depth <= 18, visited < maxNodes else { return }
        visited += 1
        AXUIElementSetMessagingTimeout(node, 0.1)
        let role = roleOf(node)

        if role == "AXStaticText" || role == "AXListMarker" {
            var valueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXValueAttribute as CFString, &valueRef) == .success,
               let text = valueRef as? String, !text.isEmpty {
                currentBlock += text
            }
            return
        }

        if nonTextControlAXRoles.contains(role) {
            return
        }

        var childrenRef: CFTypeRef?
        let hasChildren = AXUIElementCopyAttributeValue(
            node, kAXChildrenAttribute as CFString, &childrenRef) == .success
        let children = (hasChildren ? (childrenRef as? [AXUIElement]) : nil) ?? []

        // A container that directly holds AXStaticText or AXListMarker children
        // represents a single paragraph/heading/list-item flow; inline AXGroup
        // wrappers (e.g. <span>) inside it must not split the paragraph.
        let hasDirectTextChild = children.contains { child in
            let r = roleOf(child)
            return r == "AXStaticText" || r == "AXListMarker"
        }
        let isExplicitBlock = explicitBlockAXRoles.contains(role)
        let flushesBlock = isExplicitBlock || (!inParagraph && !hasDirectTextChild) ||
            (!inParagraph && hasDirectTextChild)

        if flushesBlock {
            flushBlock()
        }

        if !children.isEmpty {
            let slice: ArraySlice<AXUIElement>
            if children.count > 35 {
                if let pivotIdx = children.firstIndex(where: { child in
                    pivotChain.contains { CFEqual(child, $0) }
                }) {
                    let low = max(0, pivotIdx - 25)
                    let high = min(children.count, pivotIdx + 35)
                    slice = children[low..<high]
                } else if let selIdx = children.firstIndex(where: { child in
                    var selVal: CFTypeRef?
                    return AXUIElementCopyAttributeValue(child, kAXSelectedTextAttribute as CFString, &selVal) == .success &&
                        (selVal as? String)?.isEmpty == false
                }) {
                    let low = max(0, selIdx - 20)
                    let high = min(children.count, selIdx + 30)
                    slice = children[low..<high]
                } else {
                    slice = children[...]
                }
            } else {
                slice = children[...]
            }
            let nextInParagraph = inParagraph || hasDirectTextChild
            for child in slice {
                walk(child, depth: depth + 1, inParagraph: nextInParagraph)
            }
        }

        if flushesBlock {
            flushBlock()
        }
    }

    walk(container, depth: 0, inParagraph: false)
    flushBlock()
    return blocks
}

private func structuredSelectionText(from element: AXUIElement,
                                     hitChain: [AXUIElement] = [],
                                     raw: String) -> String {
    guard !raw.contains("\n") else { return raw }
    if let cached = structuredSelectionCache.get(for: raw) {
        return cached
    }

    // Build candidate containers starting from the local containers enclosing
    // the hit leaf element up to broader document containers.
    var candidates: [AXUIElement] = []
    func appendUnique(_ candidate: AXUIElement) {
        if !candidates.contains(where: { CFEqual($0, candidate) }) {
            candidates.append(candidate)
        }
    }

    // If we have a bottom-up chain from the pointer hit leaf, skip the leaf
    // itself and start from its immediate parent/section containers.
    for node in hitChain.dropFirst() {
        appendUnique(node)
    }

    var downChain: [AXUIElement] = [element]
    var current = element
    for _ in 0..<6 {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement],
              let selectedChild = children.first(where: { child in
                  var selVal: CFTypeRef?
                  return AXUIElementCopyAttributeValue(child, kAXSelectedTextAttribute as CFString, &selVal) == .success &&
                      (selVal as? String) == raw
              }) else { break }
        downChain.append(selectedChild)
        current = selectedChild
    }
    for node in downChain.reversed() {
        appendUnique(node)
    }

    var parentCursor = element
    for _ in 0..<8 {
        var parentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parentCursor, kAXParentAttribute as CFString, &parentRef) == .success,
              let parentRef else { break }
        let parent = parentRef as! AXUIElement
        appendUnique(parent)
        parentCursor = parent
    }

    let pivotChain = hitChain + candidates
    for candidate in candidates {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(candidate, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""
        if role == "AXStaticText" || role == "AXLink" || role == "AXListMarker" ||
           role == "AXApplication" || role == "AXWindow" {
            continue
        }
        let blocks = collectAXBlocks(from: candidate, pivotChain: pivotChain)
        if let matched = matchSelectionInBlocks(raw: raw, blocks: blocks) {
            structuredSelectionCache.set(raw: raw, structured: matched)
            return matched
        }
    }

    return raw
}

func selectionOnElement(_ element: AXUIElement,
                        pointer: CGPoint?,
                        hitChain: [AXUIElement] = []) -> (LiveSelection, Int)? {
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
    let structured = structuredSelectionText(from: element, hitChain: hitChain, raw: raw)
    let text = eligibleEnglishText(structured, maxLength: 4000)
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
func readLiveSelection(at pointer: CGPoint? = nil,
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
    var deepestHitChain: [AXUIElement] = []
    func inspectAncestors(_ start: AXUIElement) {
        var chain: [AXUIElement] = []
        var cursor: AXUIElement? = start
        for _ in 0..<28 {
            guard let node = cursor else { break }
            chain.append(node)
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString,
                                                &parent) == .success,
                  let parent else { break }
            cursor = (parent as! AXUIElement)
        }
        if chain.count > deepestHitChain.count {
            deepestHitChain = chain
        }
        for element in chain {
            if let candidate = selectionOnElement(element, pointer: pointer, hitChain: chain) {
                if candidate.0.pointHit, candidate.1 > (best?.1 ?? -1) {
                    best = candidate
                } else if !candidate.0.pointHit, candidate.0.text != nil,
                          candidate.1 > (visualCandidate?.1 ?? -1) {
                    visualCandidate = candidate
                }
            }
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
    if let focused,
       let fallback = selectionOnElement(focused as! AXUIElement,
                                         pointer: pointer,
                                         hitChain: deepestHitChain) {
        if fallback.0.pointHit, fallback.1 > (best?.1 ?? -1) {
            best = fallback
        } else if !fallback.0.pointHit, fallback.0.text != nil,
                  fallback.1 > (visualCandidate?.1 ?? -1) {
            visualCandidate = fallback
        }
    }
    if let best {
        // A child node under the pointer may confirm geometric hit for its own
        // paragraph while an ancestor (e.g. AXWebArea) holds the complete
        // multi-paragraph selection text. Preserve both the hit and full text.
        if let visualCandidate, visualCandidate.1 > best.1,
           let fullText = visualCandidate.0.text {
            return LiveSelection(text: fullText, state: best.0.state,
                                 pointHit: true,
                                 geometryAvailable: best.0.geometryAvailable)
        }
        return best.0
    }
    // Geometry from embedded web views can report a miss even while the
    // selection is visibly under the pointer. Keep the text as a candidate;
    // the captured frame decides whether it is actually highlighted here.
    if let visualCandidate { return visualCandidate.0 }
    return empty
}

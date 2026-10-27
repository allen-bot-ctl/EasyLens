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

func selectionOnElement(_ element: AXUIElement,
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

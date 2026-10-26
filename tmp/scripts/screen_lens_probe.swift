// Interactive, local-only screen OCR experiment.
// Move the pointer to any visible text and hold still for one second.
// The transparent lens is excluded from capture. No image is saved or sent anywhere.

import AppKit
import Carbon.HIToolbox
import Darwin
import NaturalLanguage
import ScreenCaptureKit
import SwiftUI
import Translation
import Vision

private func now() -> Double { ProcessInfo.processInfo.systemUptime }
private func elapsedMs(_ start: Double) -> Double { (now() - start) * 1_000 }

private func isCJK(_ scalar: Unicode.Scalar) -> Bool {
    (0x3400...0x9FFF).contains(scalar.value) ||
    (0x3040...0x30FF).contains(scalar.value) ||
    (0xAC00...0xD7AF).contains(scalar.value)
}

private struct TextResult {
    let lines: [String]
    let englishSegments: [String]
    let ocrMs: Double
    let touchesRightEdge: Bool
    let contentFrame: CGRect?
    let correctionNote: String?
}

private struct RecognizedLine {
    let text: String
    let frame: CGRect
    let ink: InkStyle?
}

private struct InkStyle {
    let luminance: CGFloat
    let lightOnDark: Bool
}

private struct GrayBitmap {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(image: CGImage) {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

// Vision can read toolbar glyphs as Latin letters. Reject those lines before
// building connected text blocks, otherwise they can bridge body text to UI metadata.
private func isEnglishLineCandidate(_ text: String) -> Bool {
    let latinCount = text.unicodeScalars.filter {
        CharacterSet.letters.contains($0) && $0.value < 128
    }.count
    guard latinCount >= 2 else { return false }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    let probabilities = recognizer.languageHypotheses(withMaximum: 3)
    let englishProbability = probabilities[.english] ?? 0
    // Short numeric UI metadata (for example a relative timestamp) tends to
    // receive a weaker English score than a sentence or title.
    let minimumProbability = latinCount < 20 &&
        text.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains)
        ? 0.75 : 0.45
    return englishProbability >= minimumProbability &&
        englishProbability == (probabilities.values.max() ?? 0)
}

private func isSingleLatinWord(_ text: String) -> Bool {
    let scalars = text.unicodeScalars
    return (4...24).contains(scalars.count) && scalars.allSatisfy {
        CharacterSet.letters.contains($0) && $0.value < 128
    }
}

private func isOneEditApart(_ first: String, _ second: String) -> Bool {
    let left = Array(first.lowercased())
    let right = Array(second.lowercased())
    guard abs(left.count - right.count) <= 1 else { return false }
    var i = 0
    var j = 0
    var edits = 0
    while i < left.count && j < right.count {
        if left[i] == right[j] {
            i += 1
            j += 1
        } else {
            edits += 1
            guard edits <= 1 else { return false }
            if left.count >= right.count { i += 1 }
            if right.count >= left.count { j += 1 }
        }
    }
    return edits + (left.count - i) + (right.count - j) == 1
}

private func correctedFocusedWord(_ raw: String) -> String? {
    guard isSingleLatinWord(raw) else { return nil }
    let checker = NSSpellChecker.shared
    func isMisspelled(_ word: String) -> Bool {
        checker.checkSpelling(of: word, startingAt: 0, language: "en_US", wrap: false,
                              inSpellDocumentWithTag: 0, wordCount: nil).location != NSNotFound
    }
    guard isMisspelled(raw) else { return nil }
    func acceptable(_ word: String) -> Bool {
        isSingleLatinWord(word) && word.lowercased().prefix(2) == raw.lowercased().prefix(2) &&
            isOneEditApart(raw, word) && !isMisspelled(word) && isEnglishLineCandidate(word)
    }
    let suggestions = checker.guesses(forWordRange: NSRange(location: 0, length: (raw as NSString).length),
                                      in: raw, language: "en_US", inSpellDocumentWithTag: 0) ?? []
    return suggestions.prefix(3).first(where: acceptable)
}

// Sample the rendered glyphs, not the app behind them. This lets a muted
// status line remain separate from a bright reply even when their edges align.
private func inkStyle(_ frame: CGRect, in bitmap: GrayBitmap?,
                      captureFrame: CGRect) -> InkStyle? {
    guard let bitmap else { return nil }
    let scaleX = CGFloat(bitmap.width) / captureFrame.width
    let scaleY = CGFloat(bitmap.height) / captureFrame.height
    let left = max(0, Int((frame.minX - captureFrame.minX) * scaleX))
    let right = min(bitmap.width, Int(ceil((frame.maxX - captureFrame.minX) * scaleX)))
    let top = max(0, Int((captureFrame.maxY - frame.maxY) * scaleY))
    let bottom = min(bitmap.height, Int(ceil((captureFrame.maxY - frame.minY) * scaleY)))
    guard right > left, bottom > top else { return nil }
    let step = max(1, Int(sqrt(Double((right - left) * (bottom - top)) / 1_200)))
    var samples: [CGFloat] = []
    for (row, y) in stride(from: top, to: bottom, by: step).enumerated() {
        // Offset successive rows so the sampling grid does not repeatedly
        // land in the spaces between glyph strokes.
        let rowStart = min(right - 1, left + (row * 7) % step)
        for x in stride(from: rowStart, to: right, by: step) {
            samples.append(CGFloat(bitmap.pixels[y * bitmap.width + x]) / 255)
        }
    }
    guard samples.count >= 20 else { return nil }
    samples.sort()
    let low = samples[samples.count / 20]
    let middle = samples[samples.count / 2]
    let high = samples[samples.count * 19 / 20]
    let lightOnDark = high - middle >= middle - low
    let contrast = lightOnDark ? high - middle : middle - low
    guard contrast >= 0.12 else { return nil }
    return InkStyle(luminance: lightOnDark ? high : low, lightOnDark: lightOnDark)
}

private func similarInk(_ first: RecognizedLine, _ second: RecognizedLine) -> Bool {
    guard let a = first.ink, let b = second.ink else { return true }
    return a.lightOnDark == b.lightOnDark && abs(a.luminance - b.luminance) <= 0.20
}

private func columnGap(_ first: RecognizedLine, _ second: RecognizedLine) -> CGFloat? {
    let upper = first.frame.midY >= second.frame.midY ? first : second
    let lower = first.frame.midY >= second.frame.midY ? second : first
    let height = max(first.frame.height, second.frame.height)
    let verticalGap = upper.frame.minY - lower.frame.maxY
    let overlap = max(0, min(first.frame.maxX, second.frame.maxX) -
                      max(first.frame.minX, second.frame.minX))
    guard verticalGap >= -height * 0.5 && verticalGap <= height * 2.5 &&
          overlap >= min(first.frame.width, second.frame.width) * 0.25 &&
          abs(first.frame.minX - second.frame.minX) <= max(120, height * 4) else {
        return nil
    }
    return verticalGap
}

private func sameTextBlock(_ first: RecognizedLine, _ second: RecognizedLine,
                           naturalGap: CGFloat) -> Bool {
    guard similarInk(first, second) else { return false }
    let height = max(first.frame.height, second.frame.height)
    let horizontalGap = max(0, max(first.frame.minX - second.frame.maxX,
                                   second.frame.minX - first.frame.maxX))
    let sameRow = abs(first.frame.midY - second.frame.midY) <= height * 0.6 &&
        horizontalGap <= height
    if sameRow { return true }
    guard let gap = columnGap(first, second) else { return false }
    // A line's nearest aligned neighbor estimates local leading. A much larger
    // gap is a block boundary; the height cap prevents distant text joining
    // when there is only one line from each block.
    return gap <= max(height * 1.25, naturalGap * 3)
}

private func distance(_ point: CGPoint, to frame: CGRect) -> CGFloat {
    let dx = max(0, max(frame.minX - point.x, point.x - frame.maxX))
    let dy = max(0, max(frame.minY - point.y, point.y - frame.maxY))
    return hypot(dx, dy)
}

// A window is a search boundary, never the final text selection. Use the
// frontmost window below our lens; if a menu or another special layer covers
// the point, keep the display-based scan instead of choosing a window behind it.
private func windowBelowLens(at point: CGPoint, lensWindowID: CGWindowID,
                             mainScreenTop: CGFloat) -> CGRect? {
    let quartzPoint = CGPoint(x: point.x, y: mainScreenTop - point.y)
    guard let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenBelowWindow, .excludeDesktopElements], lensWindowID
    ) as? [[String: Any]] else { return nil }
    for window in windows {
        guard let pid = window[kCGWindowOwnerPID as String] as? NSNumber,
              pid.int32Value != getpid(),
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let quartzFrame = CGRect(dictionaryRepresentation: bounds),
              quartzFrame.contains(quartzPoint) else { continue }
        guard let layer = window[kCGWindowLayer as String] as? NSNumber,
              layer.intValue == 0,
              quartzFrame.width >= 40, quartzFrame.height >= 40 else { return nil }
        return CGRect(x: quartzFrame.minX,
                      y: mainScreenTop - quartzFrame.maxY,
                      width: quartzFrame.width, height: quartzFrame.height)
    }
    return nil
}

// One-shot feasibility measurement for a display-wide translation surface.
// It prints counts and timing only, never recognized text or captured pixels.
@MainActor
private func benchmarkWholeDisplay(displayChoice: String = "pointer") async throws {
    let pointer = NSEvent.mouseLocation
    let targetScreen: NSScreen? = displayChoice == "main" ? NSScreen.main :
        (displayChoice == "other"
         ? NSScreen.screens.first(where: { $0 != NSScreen.main })
         : NSScreen.screens.first(where: { $0.frame.contains(pointer) }))
    guard let screen = targetScreen,
          let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                           as? NSNumber)?.uint32Value else {
        throw NSError(domain: "EasyLensScreenProbe", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "No display under pointer"])
    }
    let inventoryStart = now()
    let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                       onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
        throw NSError(domain: "EasyLensScreenProbe", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "Display unavailable"])
    }
    let inventoryMs = elapsedMs(inventoryStart)
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    config.sourceRect = CGRect(origin: .zero, size: screen.frame.size)
    config.width = Int(screen.frame.width * screen.backingScaleFactor)
    config.height = Int(screen.frame.height * screen.backingScaleFactor)
    let captureStart = now()
    let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                           configuration: config)
    let captureMs = elapsedMs(captureStart)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .fast
    request.recognitionLanguages = ["en-US", "zh-Hans"]
    request.usesLanguageCorrection = false
    let ocrStart = now()
    try VNImageRequestHandler(cgImage: image).perform([request])
    let ocrMs = elapsedMs(ocrStart)
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    let languageStart = now()
    let englishLines = lines.filter(isEnglishLineCandidate).count
    let languageMs = elapsedMs(languageStart)
    print(String(format: "DISPLAY_BENCHMARK id=%u points=%.0fx%.0f pixels=%dx%d inventoryMs=%.1f captureMs=%.1f fastOCRMs=%.1f languageMs=%.1f lines=%d englishLines=%d textSaved=no imageSaved=no cloudCalls=0",
                 displayID, screen.frame.width, screen.frame.height,
                 image.width, image.height, inventoryMs, captureMs, ocrMs,
                 languageMs, lines.count, englishLines))
    fflush(stdout)
}

private func readText(_ image: CGImage, captureFrame: CGRect,
                      anchorFrame: CGRect, focusPoint: CGPoint,
                      manualRegion: Bool = false,
                      expandedScope: Bool = false) throws -> TextResult {
    let start = now()
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .fast
    request.recognitionLanguages = ["en-US", "zh-Hans", "fr-FR"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    let bitmap = GrayBitmap(image: image)
    var allLines: [RecognizedLine] = (request.results ?? []).compactMap { observation in
        guard let text = observation.topCandidates(1).first?.string else { return nil }
        let box = observation.boundingBox
        let frame = CGRect(x: captureFrame.minX + box.minX * captureFrame.width,
                           y: captureFrame.minY + box.minY * captureFrame.height,
                           width: box.width * captureFrame.width,
                           height: box.height * captureFrame.height)
        return RecognizedLine(text: text, frame: frame,
                              ink: inkStyle(frame, in: bitmap, captureFrame: captureFrame))
    }
    var correctionNote: String?
    if let focused = allLines.indices.filter({
        isSingleLatinWord(allLines[$0].text) && distance(focusPoint, to: allLines[$0].frame) <= 60
    }).min(by: {
        distance(focusPoint, to: allLines[$0].frame) < distance(focusPoint, to: allLines[$1].frame)
    }) {
        let original = allLines[focused]
        if let corrected = correctedFocusedWord(original.text) {
            allLines[focused] = RecognizedLine(text: corrected, frame: original.frame,
                                               ink: original.ink)
            correctionNote = "OCR 校正：\(original.text) → \(corrected)"
        }
    }
    let latinIndices = allLines.indices.filter { isEnglishLineCandidate(allLines[$0].text) }
    let latinSet = Set(latinIndices)
    let visualIndices = allLines.indices.filter { index in
        let text = allLines[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        return latinSet.contains(index) || text.unicodeScalars.contains(where: isCJK) ||
            (text.unicodeScalars.count >= 2 && text.unicodeScalars.allSatisfy {
                CharacterSet.letters.contains($0) && $0.value < 128
            })
    }
    var nearestGaps: [Int: CGFloat] = [:]
    for (position, first) in latinIndices.enumerated() {
        for second in latinIndices.dropFirst(position + 1) {
            guard similarInk(allLines[first], allLines[second]),
                  let gap = columnGap(allLines[first], allLines[second]),
                  gap > max(allLines[first].frame.height, allLines[second].frame.height) * 0.15 else {
                continue
            }
            nearestGaps[first] = min(nearestGaps[first] ?? gap, gap)
            nearestGaps[second] = min(nearestGaps[second] ?? gap, gap)
        }
    }
    var unvisited = Set(latinIndices)
    var components: [[Int]] = []
    while let first = unvisited.first {
        var component = [first]
        unvisited.remove(first)
        var cursor = 0
        while cursor < component.count {
            let neighbors = unvisited.filter { neighbor in
                let current = component[cursor]
                let height = max(allLines[current].frame.height, allLines[neighbor].frame.height)
                let naturalGap = max(height * 0.35,
                                     min(nearestGaps[current] ?? height,
                                         nearestGaps[neighbor] ?? height))
                return sameTextBlock(allLines[current], allLines[neighbor],
                                     naturalGap: naturalGap)
            }
            for neighbor in neighbors {
                unvisited.remove(neighbor)
                component.append(neighbor)
            }
            cursor += 1
        }
        components.append(component)
    }
    let center = focusPoint
    let anchored = components.filter { component in
        component.contains { allLines[$0].frame.intersects(anchorFrame.insetBy(dx: -6, dy: -6)) }
    }
    func focusDistance(_ component: [Int]) -> CGFloat {
        component.map { distance(center, to: allLines[$0].frame) }.min() ?? .infinity
    }
    // A nearby text line is evidence of intent. Block length is not: choosing
    // the longest block here repeatedly stole focus from short words and labels.
    let selected = anchored.min { focusDistance($0) < focusDistance($1) }.flatMap { component in
        focusDistance(component) <= min(anchorFrame.width, anchorFrame.height) * 0.5
            ? component : nil
    }
    let focused = visualIndices.min {
        distance(center, to: allLines[$0].frame) < distance(center, to: allLines[$1].frame)
    }.flatMap { index -> Int? in
        distance(center, to: allLines[index].frame) <= 60 ? index : nil
    }
    // An enlarged lens expresses region scope; the default lens keeps focus
    // on one block. A line merely touching the enlarged lens edge is not
    // enough; long lines may extend beyond it and are completed by OCR.
    let innerLens = anchorFrame.insetBy(dx: min(8, anchorFrame.width * 0.03),
                                        dy: min(8, anchorFrame.height * 0.03))
    func substantiallyInsideLens(_ line: RecognizedLine) -> Bool {
        guard innerLens.minY <= line.frame.midY && line.frame.midY <= innerLens.maxY else {
            return false
        }
        let horizontalOverlap = max(0, min(innerLens.maxX, line.frame.maxX) -
                                    max(innerLens.minX, line.frame.minX))
        return horizontalOverlap >= min(innerLens.width, line.frame.width) * 0.6
    }
    let coveredComponents = components.filter { component in
        component.contains { substantiallyInsideLens(allLines[$0]) }
    }
    let selectedIndices: [Int]
    if manualRegion {
        selectedIndices = visualIndices.filter {
            allLines[$0].frame.intersects(anchorFrame.insetBy(dx: -2, dy: -2))
        }
    } else if expandedScope && !coveredComponents.isEmpty {
        selectedIndices = coveredComponents.flatMap { $0 }
    } else if let focused {
        selectedIndices = components.first(where: { $0.contains(focused) }) ?? [focused]
    } else {
        selectedIndices = selected ?? []
    }
    func sortedLines(_ indices: [Int]) -> [RecognizedLine] {
        indices.map { allLines[$0] }.sorted {
            if abs($0.frame.midY - $1.frame.midY) > max($0.frame.height, $1.frame.height) * 0.5 {
                return $0.frame.midY > $1.frame.midY
            }
            return $0.frame.minX < $1.frame.minX
        }
    }
    let recognized = sortedLines(selectedIndices)
    let selectedSet = Set(selectedIndices)
    let groups = components.map { $0.filter { selectedSet.contains($0) } }
        .filter { !$0.isEmpty }
        .sorted { left, right in
            let leftTop = left.map { allLines[$0].frame.maxY }.max() ?? 0
            let rightTop = right.map { allLines[$0].frame.maxY }.max() ?? 0
            return leftTop > rightTop
        }
    let segments = groups.map { sortedLines($0).map(\.text).joined(separator: " ") }.flatMap { block in
        block.split(whereSeparator: { $0.unicodeScalars.contains(where: isCJK) })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    let english = segments.filter { segment in
        guard !segment.lowercased().contains("easylens") else { return false }
        let latin = segment.unicodeScalars.filter { CharacterSet.letters.contains($0) && $0.value < 128 }
        let words = segment.split(whereSeparator: { !$0.isLetter })
        guard !words.isEmpty, latin.count >= (words.count == 1 ? 4 : 8) else { return false }
        if words.count == 1 && segment.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) {
            return false
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(segment)
        let probabilities = recognizer.languageHypotheses(withMaximum: 3)
        let englishProbability = probabilities[.english] ?? 0
        return englishProbability >= 0.45 && englishProbability == (probabilities.values.max() ?? 0)
    }
    let touchesRight = recognized.contains { line in
        let rightGap = captureFrame.maxX - line.frame.maxX
        let last = line.text.trimmingCharacters(in: .whitespacesAndNewlines).last
        return rightGap <= 18 && line.text.unicodeScalars.contains(where: {
            CharacterSet.letters.contains($0) && $0.value < 128
        }) && last?.isLetter == true
    }
    let latinLines = recognized.filter { line in
        line.text.unicodeScalars.contains(where: {
            CharacterSet.letters.contains($0) && $0.value < 128
        }) && !line.text.lowercased().contains("easylens")
    }
    let contentFrame = latinLines.isEmpty ? nil : latinLines.dropFirst().reduce(latinLines[0].frame) {
        $0.union($1.frame)
    }
    return TextResult(lines: recognized.map(\.text), englishSegments: english,
                      ocrMs: elapsedMs(start), touchesRightEdge: touchesRight,
                      contentFrame: contentFrame, correctionNote: correctionNote)
}

@MainActor
private final class LocalTranslationBridge: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    var pendingSegments: [String] = []
    var pendingGeneration = -1
    var pendingCaptureID = -1
    var onStart: ((Int, Int) -> Void)?
    var onResult: ((Int, Int, Result<([String], Double), Error>) -> Void)?

    func translate(_ segments: [String], generation: Int, captureID: Int) {
        pendingSegments = segments
        pendingGeneration = generation
        pendingCaptureID = captureID
        var next = configuration ?? .init(source: Locale.Language(identifier: "en"),
                                          target: Locale.Language(identifier: "zh-Hans"))
        next.invalidate()
        configuration = next
    }

    func cancel() {
        pendingSegments = []
        pendingGeneration = -1
        pendingCaptureID = -1
        // Keep the last configuration version. SwiftUI may not observe a nil
        // update while the panel is hidden; the next request must invalidate
        // this same value to start a new translationTask.
    }
}

@MainActor
private struct LocalTranslationTaskView: View {
    @ObservedObject var bridge: LocalTranslationBridge

    var body: some View {
        Color.clear.translationTask(bridge.configuration) { session in
            let segments = bridge.pendingSegments
            let generation = bridge.pendingGeneration
            let captureID = bridge.pendingCaptureID
            guard !segments.isEmpty else { return }
            bridge.onStart?(generation, captureID)
            let start = now()
            do {
                let requests = segments.map { TranslationSession.Request(sourceText: $0) }
                let responses = try await session.translations(from: requests)
                bridge.onResult?(generation, captureID,
                                 .success((responses.map(\.targetText), elapsedMs(start))))
            } catch {
                bridge.onResult?(generation, captureID, .failure(error))
            }
        }
    }
}

@MainActor
private final class LensView: NSView {
    var caption = "Move pointer • hold 1 s" { didSet { needsDisplay = true } }
    var preview = "" { didSet { needsDisplay = true } }
    var displaysPreview = true
    var autoExpanded = false { didSet { needsDisplay = true } }
    var manualRegion = false { didSet { needsDisplay = true } }
    var possibleTruncation = false

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10)
        border.lineWidth = 3
        (manualRegion ? NSColor.systemYellow :
            (autoExpanded ? NSColor.systemOrange : NSColor.systemBlue)).setStroke()
        border.stroke()
        if bounds.width >= 320 && bounds.height >= 110 {
            let bar = CGRect(x: 10, y: bounds.height - 31, width: min(bounds.width - 20, 285), height: 25)
            NSColor.systemBlue.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 5, yRadius: 5).fill()
            (caption as NSString).draw(at: CGPoint(x: bar.minX + 8, y: bar.minY + 4), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white
            ])
        }
        if displaysPreview && !preview.isEmpty {
            let resultBar = CGRect(x: 10, y: 8, width: bounds.width - 20, height: 70)
            NSColor.black.withAlphaComponent(0.78).setFill()
            NSBezierPath(roundedRect: resultBar, xRadius: 6, yRadius: 6).fill()
            let displayText = String(preview.prefix(180))
            (displayText as NSString).draw(in: resultBar.insetBy(dx: 9, dy: 6), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.white
            ])
        }
    }
}

@MainActor
private final class ScreenProbe: NSObject, NSApplicationDelegate {
    private let oneShot = CommandLine.arguments.contains("--once")
    private let quietText = CommandLine.arguments.contains("--quiet-text")
    private let localTranslate = CommandLine.arguments.contains("--local-translate")
    private let fixedPoint: CGPoint? = {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--point=") }) else { return nil }
        let values = argument.dropFirst("--point=".count).split(separator: ",")
        guard values.count == 2, let x = Double(values[0]), let y = Double(values[1]) else { return nil }
        return CGPoint(x: x, y: y)
    }()
    private var lensSize: CGSize = {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--lens-size=") }) else {
            return CGSize(width: 520, height: 190)
        }
        let values = argument.dropFirst("--lens-size=".count).split(separator: ",")
        guard values.count == 2, let width = Double(values[0]), let height = Double(values[1]) else {
            return CGSize(width: 520, height: 190)
        }
        return CGSize(width: max(360, min(width, 1180)), height: max(140, min(height, 550)))
    }()
    private var expandedScope: Bool { lensSize.width > 520 || lensSize.height > 190 }
    private var waitingCaption: String {
        manualRegion ? "Manual region • hold 1 s" :
            (expandedScope ? "Expanded scope • hold 1 s" : "Move pointer • hold 1 s")
    }
    private let translationBridge = LocalTranslationBridge()
    private lazy var logger = ProbeLogger()
    private var panel: NSPanel!
    private var view: LensView!
    private var resultWindow: NSPanel?
    private var resultTextView: NSTextView?
    private var pendingCorrectionNote: String?
    private var statusItem: NSStatusItem!
    private var modeMenuItem: NSMenuItem!
    private var manualRegion = false
    private var timer: Timer?
    private var displays: [CGDirectDisplayID: SCDisplay] = [:]
    private var overlayWindow: SCWindow!
    private var hotKeyHandler: EventHandlerRef?
    private var wakeHotKey: EventHotKeyRef?
    private var escapeHotKey: EventHotKeyRef?
    private var resizeHotKeys: [EventHotKeyRef] = []
    private var lastPointer = NSEvent.mouseLocation
    private var lastMoveAt = now()
    private var generation = 0
    private var capturedGeneration = -1
    private var capturing = false
    private var captureCount = 0
    private var instanceLockFD: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        let lockPath = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("EasyLensProbe.lock").path
        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR, mode_t(0o600))
        var recordLock = Darwin.flock()
        recordLock.l_type = Int16(F_WRLCK)
        recordLock.l_whence = Int16(SEEK_SET)
        guard fd >= 0, Darwin.fcntl(fd, F_SETLK, &recordLock) == 0 else {
            if fd >= 0 { Darwin.close(fd) }
            print("ERROR another EasyLens probe is running; quit its EL menu before restarting")
            fflush(stdout)
            NSApp.terminate(nil)
            return
        }
        instanceLockFD = fd
        let initialPointer = fixedPoint ?? lastPointer
        lastPointer = initialPointer
        guard let screen = screen(at: initialPointer) else {
            print("ERROR no screen at pointer")
            NSApp.terminate(nil)
            return
        }
        let frame = lensFrame(around: initialPointer, on: screen)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        view = LensView(frame: CGRect(origin: .zero, size: frame.size))
        view.displaysPreview = !localTranslate
        view.manualRegion = manualRegion
        panel.contentView = view
        if localTranslate {
            let translationView = NSHostingView(rootView: LocalTranslationTaskView(bridge: translationBridge))
            translationView.frame = view.bounds
            translationView.autoresizingMask = [.width, .height]
            view.addSubview(translationView)
            translationBridge.onStart = { [weak self] generation, captureID in
                self?.logger.event("translation.started", ["generation": generation,
                                                           "capture_id": captureID])
            }
            translationBridge.onResult = { [weak self] generation, captureID, result in
                self?.showTranslation(result, generation: generation, captureID: captureID)
            }
            Task {
                let status = await LanguageAvailability().status(
                    from: Locale.Language(identifier: "en"),
                    to: Locale.Language(identifier: "zh-Hans"))
                print("EN_TO_ZH_STATUS=\(status)")
                fflush(stdout)
            }
            configureResultWindow()
        }
        panel.orderOut(nil)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "EL"
        let menu = NSMenu()
        let showItem = NSMenuItem(title: "Show lens (⌃⌥L)", action: #selector(showLensFromMenu), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(NSMenuItem(title: "Move pointer, hold still 1 second", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "⌃⌥= / − width; add ⇧ for height", action: nil, keyEquivalent: ""))
        modeMenuItem = NSMenuItem(title: "Use manual region (⌃⌥M)",
                                  action: #selector(toggleManualRegion), keyEquivalent: "")
        modeMenuItem.target = self
        menu.addItem(modeMenuItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit EasyLens probe", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu

        installHotKeyHandler()
        print("LOCAL_SCREEN_PROBE ⌃⌥L shows lens; ⌃⌥M toggles manual region; ⌃⌥=/- resize width, add ⇧ for height; Esc hides lens")
        print("NO_TEST_TARGET_WINDOW screenshots_saved=0 cloud_calls=0 local_translation=\(localTranslate)")
        print("PROBE_LOG_PATH=\(logger.path) RUN_ID=\(logger.runID)")
        logger.event("run.started", ["local_translation": localTranslate,
                                     "one_shot": oneShot,
                                     "fixed_point": fixedPoint != nil,
                                     "lens_width": lensSize.width,
                                     "lens_height": lensSize.height])
        if let fixedPoint { print("FIXED_CAPTURE_POINT=\(fixedPoint)") }
        fflush(stdout)
        if oneShot { showLens() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let escapeHotKey { UnregisterEventHotKey(escapeHotKey) }
        if let wakeHotKey { UnregisterEventHotKey(wakeHotKey) }
        for hotKey in resizeHotKeys { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        if instanceLockFD >= 0 {
            var unlock = Darwin.flock()
            unlock.l_type = Int16(F_UNLCK)
            unlock.l_whence = Int16(SEEK_SET)
            _ = Darwin.fcntl(instanceLockFD, F_SETLK, &unlock)
            Darwin.close(instanceLockFD)
            instanceLockFD = -1
        }
    }

    private func installHotKeyHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var identity = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identity)
            guard status == noErr else { return status }
            let probe = Unmanaged<ScreenProbe>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { probe.handleHotKey(identity.id) }
            return noErr
        }, 1, &eventType, opaqueSelf, &hotKeyHandler)
        guard installed == noErr else {
            print("ERROR install hotkey handler status=\(installed)")
            return
        }
        let hotkey = EventHotKeyID(signature: OSType(0x454C4E53), id: 1)
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey),
                                            hotkey, GetApplicationEventTarget(), 0, &wakeHotKey)
        print(registered == noErr ? "WAKE_HOTKEY_REGISTERED=⌃⌥L" : "ERROR wake hotkey status=\(registered)")
        let resizeKeys: [(UInt32, UInt32, UInt32)] = [
            (3, UInt32(kVK_ANSI_Equal), UInt32(controlKey | optionKey)),
            (4, UInt32(kVK_ANSI_Minus), UInt32(controlKey | optionKey)),
            (5, UInt32(kVK_ANSI_Equal), UInt32(controlKey | optionKey | shiftKey)),
            (6, UInt32(kVK_ANSI_Minus), UInt32(controlKey | optionKey | shiftKey)),
            (7, UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey))
        ]
        for (id, keyCode, modifiers) in resizeKeys {
            var registeredKey: EventHotKeyRef?
            let status = RegisterEventHotKey(keyCode, modifiers,
                                             EventHotKeyID(signature: OSType(0x454C4E53), id: id),
                                             GetApplicationEventTarget(), 0, &registeredKey)
            if let registeredKey { resizeHotKeys.append(registeredKey) }
            if status != noErr { print("ERROR resize hotkey id=\(id) status=\(status)") }
        }
    }

    private func registerEscape() {
        guard escapeHotKey == nil else { return }
        let hotkey = EventHotKeyID(signature: OSType(0x454C4E53), id: 2)
        let status = RegisterEventHotKey(UInt32(kVK_Escape), 0, hotkey,
                                         GetApplicationEventTarget(), 0, &escapeHotKey)
        print(status == noErr ? "ESC_REGISTERED" : "ERROR Escape hotkey status=\(status)")
    }

    private func releaseEscape() {
        if let escapeHotKey {
            UnregisterEventHotKey(escapeHotKey)
            self.escapeHotKey = nil
            print("ESC_RELEASED")
        }
    }

    private func handleHotKey(_ id: UInt32) {
        if id == 1 { showLens() }
        if id == 2 { hideLens() }
        if id == 3 { resizeLens(widthDelta: 160, heightDelta: 0) }
        if id == 4 { resizeLens(widthDelta: -160, heightDelta: 0) }
        if id == 5 { resizeLens(widthDelta: 0, heightDelta: 80) }
        if id == 6 { resizeLens(widthDelta: 0, heightDelta: -80) }
        if id == 7 { toggleManualRegion() }
    }

    @objc private func toggleManualRegion() {
        manualRegion.toggle()
        modeMenuItem.title = manualRegion ? "Use automatic text (⌃⌥M)" : "Use manual region (⌃⌥M)"
        view.manualRegion = manualRegion
        let pointer = fixedPoint ?? lastPointer
        if panel.isVisible, let screen = screen(at: pointer) {
            panel.setFrame(lensFrame(around: pointer, on: screen), display: true)
            lastPointer = pointer
            lastMoveAt = now()
            generation += 1
            capturedGeneration = -1
            translationBridge.cancel()
            resultWindow?.orderOut(nil)
            pendingCorrectionNote = nil
            view.autoExpanded = false
            view.possibleTruncation = false
            view.caption = waitingCaption
        }
        logger.event("lens.mode_changed", ["manual_region": manualRegion])
        print("SELECTION_MODE=\(manualRegion ? "manual_region" : "automatic_text")")
        fflush(stdout)
    }

    private func resizeLens(widthDelta: CGFloat, heightDelta: CGFloat) {
        guard panel.isVisible else { return }
        let pointer = fixedPoint ?? NSEvent.mouseLocation
        guard let screen = screen(at: pointer) else { return }
        let oldSize = lensSize
        lensSize = CGSize(width: max(120, min(lensSize.width + widthDelta,
                                             screen.frame.width)),
                          height: max(70, min(lensSize.height + heightDelta,
                                              screen.frame.height)))
        guard lensSize != oldSize else { return }
        panel.setFrame(lensFrame(around: pointer, on: screen), display: true)
        lastPointer = pointer
        lastMoveAt = now()
        generation += 1
        capturedGeneration = -1
        translationBridge.cancel()
        resultWindow?.orderOut(nil)
        pendingCorrectionNote = nil
        view.caption = waitingCaption
        view.preview = ""
        view.autoExpanded = false
        view.possibleTruncation = false
        logger.event("lens.resized", ["generation": generation,
                                       "width": lensSize.width,
                                       "height": lensSize.height])
        print("LENS_RESIZED=\(Int(lensSize.width))x\(Int(lensSize.height))")
        fflush(stdout)
    }

    @objc private func showLensFromMenu() { showLens() }

    private func showLens() {
        let pointer = fixedPoint ?? NSEvent.mouseLocation
        lastPointer = pointer
        lastMoveAt = now()
        generation += 1
        capturedGeneration = -1
        if let screen = screen(at: pointer) {
            panel.setFrame(lensFrame(around: pointer, on: screen), display: true)
        }
        view.caption = waitingCaption
        view.preview = ""
        view.autoExpanded = false
        view.possibleTruncation = false
        translationBridge.cancel()
        resultWindow?.orderOut(nil)
        pendingCorrectionNote = nil
        panel.orderFrontRegardless()
        registerEscape()
        print("LENS_SHOWN")
        logger.event("lens.shown", ["generation": generation])
        fflush(stdout)
        Task {
            do {
                try await configureCapture()
                guard panel.isVisible else { return }
                timer?.invalidate()
                startTimer()
            } catch {
                print("ERROR capture setup: \(error)")
                fflush(stdout)
                hideLens()
                if oneShot { NSApp.terminate(nil) }
            }
        }
    }

    private func hideLens() {
        guard panel.isVisible else { return }
        generation += 1
        timer?.invalidate()
        timer = nil
        translationBridge.cancel()
        resultWindow?.orderOut(nil)
        pendingCorrectionNote = nil
        panel.orderOut(nil)
        releaseEscape()
        print("LENS_HIDDEN")
        logger.event("lens.hidden", ["generation": generation])
        fflush(stdout)
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(timeInterval: 1.0 / 30.0, target: self,
                                     selector: #selector(tick), userInfo: nil, repeats: true)
    }

    private func configureResultWindow() {
        let frame = CGRect(x: 0, y: 0, width: lensSize.width, height: 270)
        let window = NSPanel(contentRect: frame,
                             styleMask: [.titled, .closable, .resizable, .utilityWindow],
                             backing: .buffered, defer: false)
        window.title = "EasyLens · 完整译文"
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let scroll = NSScrollView(frame: CGRect(origin: .zero, size: frame.size))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = CGSize(width: 12, height: 12)
        textView.string = ""
        scroll.documentView = textView
        window.contentView = scroll
        window.orderOut(nil)
        resultWindow = window
        resultTextView = textView
    }

    private func showFullTranslation(_ segments: [String], note: String?) -> Bool {
        guard let window = resultWindow, let textView = resultTextView,
              let screen = screen(at: CGPoint(x: panel.frame.midX, y: panel.frame.midY)) else { return false }
        let translated = segments.joined(separator: "\n\n")
        textView.string = note.map { "\($0)\n\n\(translated)" } ?? translated
        textView.scrollToBeginningOfDocument(nil)
        let size = window.frame.size
        let x = max(screen.frame.minX,
                    min(panel.frame.minX, screen.frame.maxX - size.width))
        let above = panel.frame.maxY + 8
        let y = above + size.height <= screen.frame.maxY
            ? above : panel.frame.minY - size.height - 8
        window.setFrameOrigin(CGPoint(x: x, y: max(screen.frame.minY, y)))
        window.orderFrontRegardless()
        return true
    }

    private func screen(at point: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
    }

    private func lensFrame(around pointer: CGPoint, on screen: NSScreen) -> CGRect {
        let width = min(lensSize.width, screen.frame.width)
        let height = min(lensSize.height, screen.frame.height)
        let x = max(screen.frame.minX, min(pointer.x - width / 2, screen.frame.maxX - width))
        let y = max(screen.frame.minY, min(pointer.y - height / 2, screen.frame.maxY - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func configureCapture() async throws {
        try await Task.sleep(nanoseconds: 250_000_000)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        displays = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
        guard let ownWindow = content.windows.first(where: { $0.windowID == CGWindowID(panel.windowNumber) }) else {
            throw NSError(domain: "EasyLensScreenProbe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Lens window unavailable for exclusion"])
        }
        overlayWindow = ownWindow
        print("CAPTURE_READY displays=\(displays.count) lensWindow=\(panel.windowNumber)")
        fflush(stdout)
    }

    @objc private func tick() {
        guard panel.isVisible else { return }
        let pointer = fixedPoint ?? NSEvent.mouseLocation
        if fixedPoint == nil, let resultWindow, resultWindow.isVisible,
           resultWindow.frame.contains(pointer) { return }
        let distance = hypot(pointer.x - lastPointer.x, pointer.y - lastPointer.y)
        if distance > 6 {
            resultWindow?.orderOut(nil)
            lastPointer = pointer
            lastMoveAt = now()
            generation += 1
            if let screen = screen(at: pointer) {
                panel.setFrame(lensFrame(around: pointer, on: screen), display: true)
            }
            view.caption = waitingCaption
            view.preview = ""
            view.autoExpanded = false
            view.possibleTruncation = false
            translationBridge.cancel()
            pendingCorrectionNote = nil
        }
        guard !capturing, generation != capturedGeneration, now() - lastMoveAt >= 1 else { return }
        capturedGeneration = generation
        capturing = true
        view.caption = "Focused • reading locally"
        let current = generation
        let frame = panel.frame
        guard let screen = screen(at: CGPoint(x: frame.midX, y: frame.midY)) else {
            capturing = false
            return
        }
        Task { await captureAndRead(frame: frame, screen: screen, generation: current) }
    }

    private func captureAndRead(frame: CGRect, screen: NSScreen, generation current: Int) async {
        defer { capturing = false }
        do {
            guard let id = displayID(for: screen), let display = displays[id] else {
                throw NSError(domain: "EasyLensScreenProbe", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Current display not available"])
            }
            let filter = SCContentFilter(display: display, excludingWindows: [overlayWindow])
            var scanFrame: CGRect
            var windowScoped = false
            var windowReducedScan = false
            let windowLookupStart = now()
            if manualRegion {
                scanFrame = frame
            } else {
                let contextX = max(screen.frame.minX, frame.minX - frame.width - 40)
                let contextY = max(screen.frame.minY, frame.minY - 100)
                let contextRight = min(screen.frame.maxX, frame.maxX + frame.width + 40)
                let contextTop = min(screen.frame.maxY, frame.maxY + 100)
                scanFrame = CGRect(x: contextX, y: contextY,
                                   width: contextRight - contextX,
                                   height: contextTop - contextY)
                if let mainTop = NSScreen.main?.frame.maxY,
                   let windowFrame = windowBelowLens(at: lastPointer,
                                                       lensWindowID: CGWindowID(panel.windowNumber),
                                                       mainScreenTop: mainTop) {
                    let clipped = scanFrame.intersection(windowFrame)
                    if !clipped.isNull, clipped.width >= 40, clipped.height >= 40 {
                        windowReducedScan = clipped.width < scanFrame.width - 1 ||
                            clipped.height < scanFrame.height - 1
                        scanFrame = clipped
                        windowScoped = true
                    }
                }
            }
            let windowLookupMs = elapsedMs(windowLookupStart)
            let (image, captureMs) = try await capture(frame: scanFrame, screen: screen,
                                                       filter: filter)
            let focusPoint = lastPointer
            let manualSelection = manualRegion
            let expandedSelection = expandedScope
            let result = try await Task.detached(priority: .userInitiated) {
                try readText(image, captureFrame: scanFrame, anchorFrame: frame,
                             focusPoint: focusPoint, manualRegion: manualSelection,
                             expandedScope: expandedSelection)
            }.value
            guard current == self.generation else {
                print("STALE_RESULT_DISCARDED generation=\(current)")
                fflush(stdout)
                return
            }
            pendingCorrectionNote = result.correctionNote
            var finalFrame = frame
            if !manualRegion, let content = result.contentFrame {
                let width = min(screen.frame.width, max(150, min(1400, content.width + 44)))
                let height = min(screen.frame.height, max(80, min(550, content.height + 60)))
                let x = max(screen.frame.minX,
                            min(content.midX - width / 2, screen.frame.maxX - width))
                let y = max(screen.frame.minY,
                            min(content.midY - height / 2, screen.frame.maxY - height))
                finalFrame = CGRect(x: x, y: y, width: width, height: height)
                panel.setFrame(finalFrame, display: true)
                view.autoExpanded = abs(finalFrame.width - frame.width) > 10 ||
                    abs(finalFrame.height - frame.height) > 10 ||
                    abs(finalFrame.minX - frame.minX) > 10 ||
                    abs(finalFrame.minY - frame.minY) > 10
                let unfinishedParagraph = result.englishSegments.contains { paragraph in
                    let words = paragraph.split(whereSeparator: { !$0.isLetter })
                    guard words.count >= 2 else { return false }
                    guard let last = paragraph.trimmingCharacters(in: .whitespacesAndNewlines).last else {
                        return false
                    }
                    return !".!?。！？".contains(last)
                }
                view.possibleTruncation = content.width + 44 > finalFrame.width ||
                    content.height + 60 > finalFrame.height ||
                    (result.touchesRightEdge && unfinishedParagraph)
            }
            captureCount += 1
            let captureID = captureCount
            let englishChars = result.englishSegments.reduce(0) { $0 + $1.count }
            logger.event("capture.completed", ["capture_id": captureID,
                                               "generation": current,
                                               "display_id": Int(id),
                                               "capture_ms": captureMs,
                                               "ocr_ms": result.ocrMs,
                                               "ocr_corrected": result.correctionNote != nil,
                                               "ocr_lines": result.lines.count,
                                               "ocr_chars": result.lines.reduce(0) { $0 + $1.count },
                                               "english_segments": result.englishSegments.count,
                                               "english_chars": englishChars,
                                               "edge_right_detected": result.touchesRightEdge,
                                               "adaptive_capture": true,
                                               "manual_region": manualRegion,
                                               "expanded_scope": expandedSelection,
                                               "window_scoped": windowScoped,
                                               "window_reduced_scan": windowReducedScan,
                                               "window_lookup_ms": windowLookupMs,
                                               "auto_fitted": view.autoExpanded,
                                               "possible_truncation": view.possibleTruncation,
                                               "scan_width": scanFrame.width,
                                               "scan_height": scanFrame.height,
                                               "final_width": finalFrame.width,
                                               "final_height": finalFrame.height])
            print(String(format: "CAPTURE #%d display=%u scale=%.1f captureMs=%.1f fastOCRMs=%.1f lines=%d englishSegments=%d windowScoped=%@ windowClip=%@ windowLookupMs=%.1f scan=%.0fx%.0f fit=%.0fx%.0f",
                         captureCount, id, screen.backingScaleFactor, captureMs, result.ocrMs,
                         result.lines.count, result.englishSegments.count,
                         windowScoped ? "yes" : "no", windowReducedScan ? "yes" : "no", windowLookupMs,
                         scanFrame.width, scanFrame.height,
                         finalFrame.width, finalFrame.height))
            if !quietText {
                print("OCR_LINES=\(result.lines)")
                print("CANDIDATE_ENGLISH_TEXT=\(result.englishSegments)")
            }
            print("CLOUD_CALLS=0")
            fflush(stdout)
            if result.englishSegments.isEmpty {
                view.caption = manualRegion ? "No confident English • region kept" :
                    "No confident English • move"
                view.preview = result.lines.joined(separator: "  |  ")
                if oneShot { NSApp.terminate(nil) }
            } else if localTranslate {
                view.caption = manualRegion ? "Manual region • translating locally" :
                    (view.possibleTruncation ? "English found • possible crop" :
                        "English found • translating locally")
                view.preview = result.englishSegments.joined(separator: "  |  ")
                logger.event("translation.requested", ["capture_id": captureID,
                                                        "generation": current,
                                                        "segments": result.englishSegments.count,
                                                        "source_chars": englishChars])
                translationBridge.translate(result.englishSegments,
                                            generation: current, captureID: captureID)
            } else {
                view.caption = "English found • move to rescan"
                view.preview = result.lines.joined(separator: "  |  ")
                if oneShot { NSApp.terminate(nil) }
            }
        } catch {
            if current == generation {
                view.caption = "Capture failed • move to retry"
                print("ERROR capture/read: \(error)")
                fflush(stdout)
                if oneShot { NSApp.terminate(nil) }
            }
        }
    }

    private func capture(frame: CGRect, screen: NSScreen,
                         filter: SCContentFilter) async throws -> (CGImage, Double) {
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: frame.minX - screen.frame.minX,
                                   y: screen.frame.maxY - frame.maxY,
                                   width: frame.width, height: frame.height)
        config.width = Int(frame.width * screen.backingScaleFactor)
        config.height = Int(frame.height * screen.backingScaleFactor)
        let start = now()
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                               configuration: config)
        return (image, elapsedMs(start))
    }

    private func showTranslation(_ result: Result<([String], Double), Error>,
                                 generation current: Int, captureID: Int) {
        guard current == generation, panel.isVisible else {
            print("STALE_TRANSLATION_DISCARDED generation=\(current)")
            logger.event("translation.discarded", ["capture_id": captureID,
                                                    "generation": current])
            fflush(stdout)
            return
        }
        switch result {
        case .success(let (segments, milliseconds)):
            let translated = segments.joined(separator: "  |  ")
            view.caption = String(format: "本地翻译 · %.0f ms%@", milliseconds,
                                  view.possibleTruncation ? " · 可能截断" :
                                  (view.autoExpanded ? " · 已适配区域" : ""))
            let excerpt = String(translated.prefix(90))
            view.preview = "译文：\(excerpt)\(translated.count > 90 ? "… 完整译文见窗口" : "")"
            let presented = showFullTranslation(segments, note: pendingCorrectionNote)
            print(String(format: "LOCAL_TRANSLATION_MS=%.1f", milliseconds))
            logger.event("translation.completed", ["capture_id": captureID,
                                                     "generation": current,
                                                     "responses": segments.count,
                                                     "translated_chars": segments.reduce(0) { $0 + $1.count },
                                                     "translation_ms": milliseconds])
            if presented {
                logger.event("translation.presented", ["capture_id": captureID,
                                                         "generation": current,
                                                         "displayed_chars": segments.reduce(0) { $0 + $1.count }])
            }
            if !quietText { print("TARGET_CHINESE_TEXT=\(translated)") }
            print("CLOUD_CALLS=0")
        case .failure(let error):
            view.caption = "Local translation failed"
            print("LOCAL_TRANSLATION_ERROR=\(error)")
            logger.event("translation.failed", ["capture_id": captureID,
                                                  "generation": current,
                                                  "error_type": String(reflecting: type(of: error))])
        }
        fflush(stdout)
        if oneShot { NSApp.terminate(nil) }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

private struct DisplayTextBlock {
    let text: String
    let frame: CGRect
}

private struct DisplayTextResult {
    let blocks: [DisplayTextBlock]
    let lineCount: Int
    let ocrMs: Double
}

// Use the same line geometry as the lens, but retain every English block on
// the chosen display. The pointer no longer decides which block is translated.
private func readWholeDisplay(_ image: CGImage, displayFrame: CGRect) throws -> DisplayTextResult {
    let start = now()
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .fast
    request.recognitionLanguages = ["en-US", "zh-Hans", "fr-FR"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    let bitmap = GrayBitmap(image: image)
    let lines: [RecognizedLine] = (request.results ?? []).compactMap { observation in
        guard let text = observation.topCandidates(1).first?.string else { return nil }
        let box = observation.boundingBox
        let frame = CGRect(x: displayFrame.minX + box.minX * displayFrame.width,
                           y: displayFrame.minY + box.minY * displayFrame.height,
                           width: box.width * displayFrame.width,
                           height: box.height * displayFrame.height)
        return RecognizedLine(text: text, frame: frame,
                              ink: inkStyle(frame, in: bitmap, captureFrame: displayFrame))
    }
    let candidates = lines.indices.filter { isEnglishLineCandidate(lines[$0].text) }
    var nearestGaps: [Int: CGFloat] = [:]
    for (position, first) in candidates.enumerated() {
        for second in candidates.dropFirst(position + 1) {
            guard similarInk(lines[first], lines[second]),
                  let gap = columnGap(lines[first], lines[second]),
                  gap > max(lines[first].frame.height, lines[second].frame.height) * 0.15 else {
                continue
            }
            nearestGaps[first] = min(nearestGaps[first] ?? gap, gap)
            nearestGaps[second] = min(nearestGaps[second] ?? gap, gap)
        }
    }
    var remaining = Set(candidates)
    var groups: [[Int]] = []
    while let first = remaining.first {
        var group = [first]
        remaining.remove(first)
        var cursor = 0
        while cursor < group.count {
            let neighbors = remaining.filter { neighbor in
                let current = group[cursor]
                let height = max(lines[current].frame.height, lines[neighbor].frame.height)
                let naturalGap = max(height * 0.35,
                                     min(nearestGaps[current] ?? height,
                                         nearestGaps[neighbor] ?? height))
                return sameTextBlock(lines[current], lines[neighbor], naturalGap: naturalGap)
            }
            for neighbor in neighbors {
                remaining.remove(neighbor)
                group.append(neighbor)
            }
            cursor += 1
        }
        groups.append(group)
    }
    let blocks = groups.compactMap { group -> DisplayTextBlock? in
        let ordered = group.sorted {
            if abs(lines[$0].frame.midY - lines[$1].frame.midY) >
                max(lines[$0].frame.height, lines[$1].frame.height) * 0.5 {
                return lines[$0].frame.midY > lines[$1].frame.midY
            }
            return lines[$0].frame.minX < lines[$1].frame.minX
        }
        guard let first = ordered.first else { return nil }
        let text = ordered.map { lines[$0].text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.lowercased().contains("easylens"),
              !text.unicodeScalars.contains(where: isCJK) else { return nil }
        let frame = ordered.dropFirst().reduce(lines[first].frame) {
            $0.union(lines[$1].frame)
        }
        return DisplayTextBlock(text: text, frame: frame)
    }.sorted {
        if abs($0.frame.maxY - $1.frame.maxY) > 12 { return $0.frame.maxY > $1.frame.maxY }
        return $0.frame.minX < $1.frame.minX
    }
    return DisplayTextResult(blocks: blocks, lineCount: lines.count,
                             ocrMs: elapsedMs(start))
}

private struct DisplayOverlayCard {
    let source: CGRect
    let frame: CGRect
    let text: String
    let font: NSFont
}

@MainActor
private final class DisplayOverlayView: NSView {
    var cards: [DisplayOverlayCard] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for card in cards {
            if !card.frame.intersects(card.source.insetBy(dx: -12, dy: -12)) {
                NSColor.systemBlue.withAlphaComponent(0.75).setStroke()
                let line = NSBezierPath()
                line.move(to: CGPoint(x: card.source.midX, y: card.source.midY))
                line.line(to: CGPoint(x: card.frame.midX, y: card.frame.midY))
                line.lineWidth = 1.5
                line.stroke()
            }
            NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
            let path = NSBezierPath(roundedRect: card.frame, xRadius: 9, yRadius: 9)
            path.fill()
            NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 1.5
            path.stroke()
            (card.text as NSString).draw(in: card.frame.insetBy(dx: 10, dy: 8),
                                         withAttributes: [.font: card.font,
                                                          .foregroundColor: NSColor.white])
        }
    }

    func layoutCards(blocks: [DisplayTextBlock], translations: [String],
                     displayOrigin: CGPoint) -> Int {
        var placed: [DisplayOverlayCard] = []
        var collisions = 0
        for (block, translation) in zip(blocks, translations) {
            let source = block.frame.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
            let font = NSFont.systemFont(ofSize: min(25, max(14, source.height * 0.75)),
                                         weight: .medium)
            let width = min(max(source.width + 20, 120), bounds.width - 16)
            let textWidth = width - 20
            let textHeight = (translation as NSString).boundingRect(
                with: CGSize(width: textWidth, height: 2000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            ).height
            let height = min(bounds.height - 16, max(source.height + 16, ceil(textHeight) + 20))
            let x = max(8, min(source.minX - 8, bounds.width - width - 8))
            let centeredY = source.midY - height / 2
            var yCandidates: [CGFloat] = [centeredY, source.maxY + 8,
                                          source.minY - height - 8]
            for offset in stride(from: CGFloat(28), through: CGFloat(280), by: CGFloat(28)) {
                yCandidates.append(centeredY + offset)
                yCandidates.append(centeredY - offset)
            }
            var best = CGRect(x: x, y: 8, width: width, height: height)
            var bestScore = CGFloat.infinity
            for candidateY in yCandidates {
                let y = max(8, min(candidateY, bounds.height - height - 8))
                let frame = CGRect(x: x, y: y, width: width, height: height)
                let overlap = placed.reduce(CGFloat.zero) { sum, other in
                    let intersection = frame.intersection(other.frame)
                    return sum + (intersection.isNull ? 0 : intersection.width * intersection.height)
                }
                let score = overlap * 10 + abs(frame.midY - source.midY)
                if score < bestScore { best = frame; bestScore = score }
            }
            if placed.contains(where: { $0.frame.intersects(best) }) { collisions += 1 }
            placed.append(DisplayOverlayCard(source: source, frame: best,
                                             text: translation, font: font))
        }
        cards = placed
        return collisions
    }
}

@MainActor
private final class FullDisplayProbe: NSObject, NSApplicationDelegate {
    private let oneShot = CommandLine.arguments.contains("--once")
    private let showText = CommandLine.arguments.contains("--show-text")
    private let fixedPoint: CGPoint? = {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--point=") }) else {
            return nil
        }
        let values = argument.dropFirst("--point=".count).split(separator: ",")
        guard values.count == 2, let x = Double(values[0]), let y = Double(values[1]) else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }()
    private let bridge = LocalTranslationBridge()
    private lazy var logger = ProbeLogger()
    private var statusItem: NSStatusItem!
    private var panel: NSPanel?
    private var overlayView: DisplayOverlayView?
    private var hotKeyHandler: EventHandlerRef?
    private var wakeHotKey: EventHotKeyRef?
    private var escapeHotKey: EventHotKeyRef?
    private var lockFD: Int32 = -1
    private var generation = 0
    private var capturing = false
    private var blocks: [DisplayTextBlock] = []
    private var displayOrigin = CGPoint.zero
    private var startedAt = 0.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let lockPath = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("EasyLensProbe.lock").path
        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR, mode_t(0o600))
        var recordLock = Darwin.flock()
        recordLock.l_type = Int16(F_WRLCK)
        recordLock.l_whence = Int16(SEEK_SET)
        guard fd >= 0, Darwin.fcntl(fd, F_SETLK, &recordLock) == 0 else {
            if fd >= 0 { Darwin.close(fd) }
            print("ERROR another EasyLens probe is running; quit its EL menu before restarting")
            NSApp.terminate(nil)
            return
        }
        lockFD = fd
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "EL"
        let menu = NSMenu()
        let translate = NSMenuItem(title: "Translate display (⌃⌥L)",
                                   action: #selector(translateFromMenu), keyEquivalent: "")
        translate.target = self
        menu.addItem(translate)
        let hide = NSMenuItem(title: "Hide translation (Esc)",
                              action: #selector(hideFromMenu), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit EasyLens probe", action: #selector(quitProbe),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        installHotKeys()
        bridge.onResult = { [weak self] generation, _, result in
            self?.showTranslation(result, generation: generation)
        }
        print("FULL_DISPLAY_PROBE ⌃⌥L translates pointer display; Esc hides; EL menu quits")
        print("PROBE_LOG_PATH=\(logger.path) RUN_ID=\(logger.runID)")
        print("CLOUD_CALLS=0")
        fflush(stdout)
        if oneShot { startTranslation() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeHotKey { UnregisterEventHotKey(wakeHotKey) }
        if let escapeHotKey { UnregisterEventHotKey(escapeHotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        if lockFD >= 0 {
            var unlock = Darwin.flock()
            unlock.l_type = Int16(F_UNLCK)
            unlock.l_whence = Int16(SEEK_SET)
            _ = Darwin.fcntl(lockFD, F_SETLK, &unlock)
            Darwin.close(lockFD)
        }
    }

    private func installHotKeys() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var identity = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identity)
            guard status == noErr else { return status }
            let probe = Unmanaged<FullDisplayProbe>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                if identity.id == 1 { probe.startTranslation() }
                if identity.id == 2 { probe.hideTranslation() }
            }
            return noErr
        }, 1, &eventType, opaqueSelf, &hotKeyHandler)
        guard installed == noErr else { print("ERROR install hotkey handler status=\(installed)"); return }
        let hotkey = EventHotKeyID(signature: OSType(0x454C4653), id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey),
                                         hotkey, GetApplicationEventTarget(), 0, &wakeHotKey)
        print(status == noErr ? "WAKE_HOTKEY_REGISTERED=⌃⌥L" :
              "ERROR wake hotkey status=\(status)")
    }

    private func registerEscape() {
        guard escapeHotKey == nil else { return }
        let hotkey = EventHotKeyID(signature: OSType(0x454C4653), id: 2)
        let status = RegisterEventHotKey(UInt32(kVK_Escape), 0, hotkey,
                                         GetApplicationEventTarget(), 0, &escapeHotKey)
        if status != noErr { print("ERROR Escape hotkey status=\(status)") }
    }

    private func releaseEscape() {
        if let escapeHotKey { UnregisterEventHotKey(escapeHotKey); self.escapeHotKey = nil }
    }

    @objc private func translateFromMenu() { startTranslation() }
    @objc private func hideFromMenu() { hideTranslation() }
    @objc private func quitProbe() { NSApp.terminate(nil) }

    private func startTranslation() {
        guard !capturing else { return }
        generation += 1
        let current = generation
        startedAt = now()
        bridge.cancel()
        panel?.orderOut(nil)
        releaseEscape()
        statusItem.button?.title = "EL…"
        capturing = true
        Task { await captureAndTranslate(generation: current) }
    }

    private func hideTranslation() {
        generation += 1
        bridge.cancel()
        panel?.orderOut(nil)
        releaseEscape()
        statusItem.button?.title = "EL"
        logger.event("full_display.hidden", ["generation": generation])
        print("OVERLAY_HIDDEN")
        fflush(stdout)
    }

    private func configureOverlay(for screen: NSScreen) {
        if panel == nil {
            let window = NSPanel(contentRect: screen.frame,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            window.level = .floating
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = DisplayOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
            window.contentView = view
            let host = NSHostingView(rootView: LocalTranslationTaskView(bridge: bridge))
            host.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            view.addSubview(host)
            panel = window
            overlayView = view
        } else {
            panel?.setFrame(screen.frame, display: true)
            overlayView?.frame = CGRect(origin: .zero, size: screen.frame.size)
            overlayView?.cards = []
        }
    }

    private func captureAndTranslate(generation current: Int) async {
        defer { capturing = false }
        do {
            let pointer = fixedPoint ?? NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }),
                  let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                            as? NSNumber)?.uint32Value else {
                throw NSError(domain: "EasyLensFullDisplayProbe", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "No display under pointer"])
            }
            let inventoryStart = now()
            let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                               onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw NSError(domain: "EasyLensFullDisplayProbe", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Display unavailable"])
            }
            let inventoryMs = elapsedMs(inventoryStart)
            let overlayID = panel.map { CGWindowID($0.windowNumber) }
            let excluded = content.windows.filter { window in
                overlayID == window.windowID
            }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(origin: .zero, size: screen.frame.size)
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            let captureStart = now()
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                   configuration: config)
            let captureMs = elapsedMs(captureStart)
            let frame = screen.frame
            let result = try await Task.detached(priority: .userInitiated) {
                try readWholeDisplay(image, displayFrame: frame)
            }.value
            guard current == generation else { return }
            blocks = result.blocks
            displayOrigin = screen.frame.origin
            logger.event("full_display.capture_completed", [
                "generation": current, "display_id": Int(id),
                "inventory_ms": inventoryMs, "capture_ms": captureMs,
                "ocr_ms": result.ocrMs, "ocr_lines": result.lineCount,
                "english_blocks": blocks.count,
                "source_chars": blocks.reduce(0) { $0 + $1.text.count }
            ])
            print(String(format: "FULL_DISPLAY_CAPTURE display=%u inventoryMs=%.1f captureMs=%.1f fastOCRMs=%.1f lines=%d englishBlocks=%d",
                         id, inventoryMs, captureMs, result.ocrMs,
                         result.lineCount, blocks.count))
            if showText { print("ENGLISH_BLOCKS=\(blocks.map(\.text))") }
            fflush(stdout)
            guard !blocks.isEmpty else {
                statusItem.button?.title = "EL"
                print("NO_ENGLISH_BLOCKS cloudCalls=0")
                fflush(stdout)
                if oneShot { NSApp.terminate(nil) }
                return
            }
            configureOverlay(for: screen)
            panel?.orderFrontRegardless()
            registerEscape()
            logger.event("full_display.translation_requested", [
                "generation": current, "segments": blocks.count
            ])
            bridge.translate(blocks.map(\.text), generation: current, captureID: current)
        } catch {
            if current == generation {
                statusItem.button?.title = "EL"
                print("FULL_DISPLAY_ERROR=\(error)")
                logger.event("full_display.failed", ["generation": current,
                                                      "error_type": String(reflecting: type(of: error))])
                fflush(stdout)
                if oneShot { NSApp.terminate(nil) }
            }
        }
    }

    private func showTranslation(_ result: Result<([String], Double), Error>,
                                 generation current: Int) {
        guard current == generation else { return }
        statusItem.button?.title = "EL"
        switch result {
        case .success(let (translations, translationMs)):
            guard translations.count == blocks.count else {
                print("FULL_DISPLAY_ERROR=translation count mismatch")
                fflush(stdout)
                return
            }
            let collisions = overlayView?.layoutCards(blocks: blocks,
                                                       translations: translations,
                                                       displayOrigin: displayOrigin) ?? 0
            let totalMs = elapsedMs(startedAt)
            logger.event("full_display.translation_completed", [
                "generation": current, "responses": translations.count,
                "translated_chars": translations.reduce(0) { $0 + $1.count },
                "translation_ms": translationMs, "total_ms": totalMs,
                "overlapping_cards": collisions
            ])
            print(String(format: "FULL_DISPLAY_TRANSLATION blocks=%d translationMs=%.1f totalMs=%.1f overlappingCards=%d cloudCalls=0",
                         translations.count, translationMs, totalMs, collisions))
            if showText { print("TARGET_CHINESE_TEXT=\(translations)") }
        case .failure(let error):
            print("FULL_DISPLAY_TRANSLATION_ERROR=\(error)")
            logger.event("full_display.translation_failed", ["generation": current,
                                                               "error_type": String(reflecting: type(of: error))])
        }
        fflush(stdout)
        if oneShot {
            if CommandLine.arguments.contains("--linger") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { NSApp.terminate(nil) }
            } else {
                NSApp.terminate(nil)
            }
        }
    }
}

@main
private enum ScreenProbeMain {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--whole-display") {
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                let probe = FullDisplayProbe()
                app.delegate = probe
                app.run()
            }
            return
        }
        if arguments.contains("--benchmark-display") ||
            arguments.contains("--benchmark-main-display") ||
            arguments.contains("--benchmark-other-display") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                do {
                    let choice = arguments.contains("--benchmark-main-display") ? "main" :
                        (arguments.contains("--benchmark-other-display") ? "other" : "pointer")
                    try await benchmarkWholeDisplay(displayChoice: choice)
                }
                catch { print("DISPLAY_BENCHMARK_ERROR=\(error)") }
                fflush(stdout)
                app.terminate(nil)
            }
            app.run()
            return
        }
        if arguments.count > 1, arguments[1] == "--inspect-image" {
            let regionOption = arguments.count == 8 ? arguments[5] : ""
            let manual = regionOption == "--manual"
            guard arguments.count == 5 || manual || regionOption == "--lens",
                  let image = NSImage(contentsOfFile: arguments[2])?
                    .cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let x = Double(arguments[3]), let y = Double(arguments[4]),
                  let width = arguments.count == 8 ? Double(arguments[6]) : 520,
                  let height = arguments.count == 8 ? Double(arguments[7]) : 190 else {
                fputs("Usage: --inspect-image <path> <x> <y> [--lens|--manual <width> <height>] (pixels from lower left)\n", stderr)
                exit(2)
            }
            let frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let anchor = CGRect(x: x - width / 2, y: y - height / 2,
                                width: width, height: height)
            do {
                let result = try readText(image, captureFrame: frame,
                                          anchorFrame: anchor, focusPoint: CGPoint(x: x, y: y),
                                          manualRegion: manual,
                                          expandedScope: regionOption == "--lens" &&
                                              (width > 520 || height > 190))
                print("SELECTED_OCR_LINES=\(result.lines)")
                print("ENGLISH_SEGMENTS=\(result.englishSegments)")
                print("CONTENT_FRAME=\(String(describing: result.contentFrame))")
                print("CORRECTION_NOTE=\(result.correctionNote ?? "none")")
                print(String(format: "OCR_MS=%.1f", result.ocrMs))
            } catch {
                fputs("Image OCR failed: \(error)\n", stderr)
                exit(1)
            }
            return
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let probe = ScreenProbe()
            app.delegate = probe
            app.run()
        }
    }
}

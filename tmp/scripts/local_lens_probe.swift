// Local-only EasyLens feasibility probe. Captures only the test window created below.
// No screenshots are saved and no network requests are made.

import AppKit
import NaturalLanguage
import ScreenCaptureKit
import Vision

private func now() -> Double { ProcessInfo.processInfo.systemUptime }
private func milliseconds(_ start: Double) -> Double { (now() - start) * 1_000 }

private struct Sample {
    let name: String
    let text: String
    let expectedFragment: String
    let y: CGFloat
    let shouldPass: Bool
}

private struct OCRResult {
    let lines: [String]
    let elapsedMs: Double
    let eligibleLines: [String]
}

private func isCJK(_ scalar: Unicode.Scalar) -> Bool {
    (0x3400...0x9FFF).contains(scalar.value) ||
    (0x3040...0x30FF).contains(scalar.value) ||
    (0xAC00...0xD7AF).contains(scalar.value)
}

private func recognize(_ image: CGImage, level: VNRequestTextRecognitionLevel) throws -> OCRResult {
    let start = now()
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = level
    request.recognitionLanguages = ["en-US", "zh-Hans", "fr-FR"]
    request.usesLanguageCorrection = false
    let handler = VNImageRequestHandler(cgImage: image)
    try handler.perform([request])
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    let segments = lines.flatMap { line in
        line.split(whereSeparator: { character in
            character == "." || character == "。" || character.unicodeScalars.contains(where: isCJK)
        }).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    let eligible = segments.filter { segment in
        let latinLetters = segment.unicodeScalars.filter { CharacterSet.letters.contains($0) && $0.value < 128 }
        let words = segment.split(whereSeparator: { !$0.isLetter })
        guard latinLetters.count >= 8, words.count >= 2 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(segment)
        let probabilities = recognizer.languageHypotheses(withMaximum: 3)
        let english = probabilities[.english] ?? 0
        let highest = probabilities.values.max() ?? 0
        // This is an experiment threshold, not a production language policy.
        return english >= 0.45 && english == highest
    }
    return OCRResult(lines: lines, elapsedMs: milliseconds(start), eligibleLines: eligible)
}

private func darkTextSamples(_ image: CGImage, scale: CGFloat) -> Int {
    let bitmap = NSBitmapImageRep(cgImage: image)
    var dark = 0
    for y in stride(from: Int(10 * scale), to: image.height - Int(10 * scale), by: 6) {
        for x in stride(from: Int(25 * scale), to: image.width - Int(10 * scale), by: 6) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if color.redComponent < 0.3 && color.greenComponent < 0.3 && color.blueComponent < 0.3 {
                dark += 1
            }
        }
    }
    return dark
}

private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))
    return sorted[index]
}

@MainActor
private final class Probe: NSObject, NSApplicationDelegate {
    private var target: NSWindow!
    private var lens: NSPanel!
    private var testScreen: NSScreen!
    private var display: SCDisplay!
    private var lensWindow: SCWindow!

    private let samples = [
        Sample(name: "english", text: "The quick brown fox jumps over the lazy dog.", expectedFragment: "quick brown fox", y: 398, shouldPass: true),
        Sample(name: "chinese", text: "这是一段中文，不应该提交到云端。", expectedFragment: "中文", y: 298, shouldPass: false),
        Sample(name: "french", text: "Bonjour, ceci est une phrase française.", expectedFragment: "Bonjour", y: 198, shouldPass: false),
        Sample(name: "mixed", text: "Hello world. 你好世界", expectedFragment: "Hello world", y: 98, shouldPass: true)
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else {
            print("ERROR no display")
            NSApp.terminate(nil)
            return
        }
        testScreen = screen
        let contentRect = CGRect(x: screen.visibleFrame.midX - 390,
                                 y: screen.visibleFrame.midY - 290,
                                 width: 780, height: 550)
        target = NSWindow(contentRect: contentRect,
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        target.title = "EasyLens local OCR test target"
        target.backgroundColor = .white
        target.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        for sample in samples {
            let row = NSView(frame: CGRect(x: 45, y: sample.y, width: 690, height: 77))
            row.wantsLayer = true
            row.layer?.backgroundColor = NSColor.white.cgColor
            let marker = NSView(frame: CGRect(x: 0, y: 0, width: 14, height: 77))
            marker.wantsLayer = true
            marker.layer?.backgroundColor = NSColor.magenta.cgColor
            row.addSubview(marker)
            let label = NSTextField(labelWithString: sample.text)
            label.frame = CGRect(x: 22, y: 10, width: 660, height: 52)
            label.font = NSFont.systemFont(ofSize: 25, weight: .medium)
            label.textColor = .black
            row.addSubview(label)
            target.contentView?.addSubview(row)
        }
        target.makeKeyAndOrderFront(nil)

        lens = NSPanel(contentRect: lensFrame(for: samples[0]),
                       styleMask: [.borderless, .nonactivatingPanel],
                       backing: .buffered, defer: false)
        lens.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        lens.isOpaque = true
        lens.backgroundColor = NSColor(calibratedRed: 0.98, green: 0.75, blue: 0.12, alpha: 1)
        lens.ignoresMouseEvents = true
        let maskLabel = NSTextField(labelWithString: "EASYLENS MASK")
        maskLabel.frame = CGRect(x: 120, y: 18, width: 390, height: 43)
        maskLabel.font = NSFont.boldSystemFont(ofSize: 34)
        maskLabel.textColor = .black
        lens.contentView?.addSubview(maskLabel)
        lens.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        print("LOCAL_ONLY app=EasyLensProbe macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        fflush(stdout)
        Task { await run() }
    }

    private func lensFrame(for sample: Sample) -> CGRect {
        // The lens covers the exact line in the app-owned test target.
        let screen = testScreen ?? NSScreen.main!
        let contentOrigin = CGPoint(x: screen.visibleFrame.midX - 390,
                                    y: screen.visibleFrame.midY - 290)
        return CGRect(x: contentOrigin.x + 45, y: contentOrigin.y + sample.y,
                      width: 690, height: 77)
    }

    private func setupCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = (testScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let id = displayID,
              let foundDisplay = content.displays.first(where: { $0.displayID == id }),
              let foundLens = content.windows.first(where: { $0.windowID == CGWindowID(lens.windowNumber) }) else {
            throw NSError(domain: "EasyLensProbe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Display or overlay window not found by ScreenCaptureKit"])
        }
        display = foundDisplay
        lensWindow = foundLens
        print("CAPTURE_READY display=\(id) overlayWindow=\(lens.windowNumber) scale=\(testScreen.backingScaleFactor)")
    }

    private func capture(excludeLens: Bool) async throws -> (CGImage, Double) {
        let frame = lens.frame
        let screen = testScreen.frame
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: frame.minX - screen.minX,
                                   y: screen.maxY - frame.maxY,
                                   width: frame.width, height: frame.height)
        config.width = Int(frame.width * testScreen.backingScaleFactor)
        config.height = Int(frame.height * testScreen.backingScaleFactor)
        let excluded: [SCWindow] = excludeLens ? [lensWindow] : []
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let start = now()
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        if excludeLens {
            let markerX = Int(5 * testScreen.backingScaleFactor)
            let markerY = Int(5 * testScreen.backingScaleFactor)
            let pixel = NSBitmapImageRep(cgImage: image).colorAt(x: markerX, y: markerY)?
                .usingColorSpace(.deviceRGB)
            guard let pixel, pixel.redComponent > 0.75,
                  pixel.greenComponent < 0.4, pixel.blueComponent > 0.75 else {
                if let pixel {
                    print(String(format: "TARGET_MARKER_MISS rgb=%.2f,%.2f,%.2f",
                                 pixel.redComponent, pixel.greenComponent, pixel.blueComponent))
                } else {
                    print("TARGET_MARKER_MISS pixel unavailable")
                }
                throw NSError(domain: "EasyLensProbe", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Test target marker is not visible; refusing OCR of another window"])
            }
        }
        return (image, milliseconds(start))
    }

    private func run() async {
        do {
            try await setupCapture()
            // Leave the target visible and the lens stationary for the proposed 1 s focus interval.
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let (withMask, _) = try await capture(excludeLens: false)
            let (withoutMask, _) = try await capture(excludeLens: true)
            let includedOCR = try recognize(withMask, level: .accurate)
            let excludedOCR = try recognize(withoutMask, level: .accurate)
            let maskFound = includedOCR.lines.joined(separator: " ").contains("EASYLENS MASK")
            let targetFound = excludedOCR.lines.joined(separator: " ").contains(samples[0].expectedFragment)
            print("OVERLAY_CHECK includedHasMask=\(maskFound) excludedHasTarget=\(targetFound)")
            guard maskFound, targetFound else {
                throw NSError(domain: "EasyLensProbe", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Overlay or target text did not match the controlled test"])
            }

            for (index, sample) in samples.enumerated() {
                if index > 0 {
                    lens.setFrame(lensFrame(for: sample), display: true)
                    // A move invalidates the previous snapshot; this is one stable-frame focus cycle.
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                let count = index == 0 ? 20 : 5
                var captureTimes: [Double] = []
                var fastTimes: [Double] = []
                var accurateTimes: [Double] = []
                var matches = 0
                var gatePasses = 0
                var fastMatches = 0
                var fastGatePasses = 0
                var firstEligible: String?
                for repetition in 0..<count {
                    let (image, captureMs) = try await capture(excludeLens: true)
                    let fast = try recognize(image, level: .fast)
                    let accurate = try recognize(image, level: .accurate)
                    captureTimes.append(captureMs)
                    fastTimes.append(fast.elapsedMs)
                    accurateTimes.append(accurate.elapsedMs)
                    if accurate.lines.joined(separator: " ").contains(sample.expectedFragment) { matches += 1 }
                    if !accurate.eligibleLines.isEmpty { gatePasses += 1 }
                    if fast.lines.joined(separator: " ").contains(sample.expectedFragment) { fastMatches += 1 }
                    if !fast.eligibleLines.isEmpty { fastGatePasses += 1 }
                    if firstEligible == nil { firstEligible = accurate.eligibleLines.first }
                    if repetition == 0 {
                        print("OCR_SAMPLE \(sample.name) darkTextSamples=\(darkTextSamples(image, scale: testScreen.backingScaleFactor)) fastLines=\(fast.lines) accurateLines=\(accurate.lines) eligible=\(accurate.eligibleLines)")
                    }
                }
                let n = captureTimes.count
                print(String(format: "CASE %@ n=%d fastMatch=%d fastGatePass=%d accurateMatch=%d accurateGatePass=%d expectedGate=%@ captureMs[p50=%.1f,p95=%.1f] fastOCRMs[p50=%.1f,p95=%.1f] accurateOCRMs[p50=%.1f,p95=%.1f]",
                             sample.name, n, fastMatches, fastGatePasses, matches, gatePasses, sample.shouldPass ? "pass" : "skip",
                             percentile(captureTimes, 0.5), percentile(captureTimes, 0.95),
                             percentile(fastTimes, 0.5), percentile(fastTimes, 0.95),
                             percentile(accurateTimes, 0.5), percentile(accurateTimes, 0.95)))
                if sample.shouldPass, let text = firstEligible, matches > 0 {
                    print("READY_FOR_CLOUD_TEXT=\(text)")
                    print("CLOUD_CALLS=0")
                }
                fflush(stdout)
            }
            print("DONE local pipeline stopped before network/API")
        } catch {
            print("ERROR \(error)")
            print("DONE local pipeline stopped before network/API")
        }
        fflush(stdout)
        NSApp.terminate(nil)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let probe = Probe()
    app.delegate = probe
    app.run()
}

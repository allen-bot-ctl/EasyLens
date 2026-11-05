// Migrated from the validated macOS lens prototype.
import AppKit
import ImageIO

@main
enum EasyLensMain {
    @MainActor static func main() {
        #if DEBUG
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
            if args.contains("--dump-selection"), let text = selection.text {
                let paragraphCount = text.components(separatedBy: "\n").count
                print("AX_SELECTION_PARAGRAPHS=\(paragraphCount) text=\(String(reflecting: text))")
            }
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
        #endif
        let app = NSApplication.shared
        let delegate = EasyLensAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

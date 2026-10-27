// Migrated from the validated macOS lens prototype.
import AppKit
import SwiftUI

#if DEBUG
@MainActor
final class FocusTranslationSelfTest: NSObject, NSApplicationDelegate {
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
final class SelectionTranslationSelfTest: NSObject, NSApplicationDelegate {
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
#endif

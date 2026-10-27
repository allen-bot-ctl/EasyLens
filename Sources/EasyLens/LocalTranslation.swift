// Migrated from the validated macOS lens prototype.
import AppKit
import SwiftUI
import Translation

@MainActor
final class WordTranslationBridge: ObservableObject {
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

struct FocusedTranslation {
    let chinese: String?
    let basis: String
}

@MainActor
final class SelectionTranslationBridge: ObservableObject {
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
struct SelectionTranslationTaskView: View {
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
struct TranslationTaskView: View {
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

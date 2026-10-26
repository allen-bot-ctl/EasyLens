// Local-only macOS Translation framework experiment. A real window is required
// so the system can request consent to download missing language models.

import AppKit
import SwiftUI
import Translation

private func now() -> Double { ProcessInfo.processInfo.systemUptime }

private struct TranslationProbeView: View {
    @State private var source = {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--text"), index + 1 < args.count {
            return args[index + 1]
        }
        return "The quick brown fox jumps over the lazy dog."
    }()
    @State private var result = ""
    @State private var status = "Checking English → Simplified Chinese availability…"
    @State private var configuration: TranslationSession.Configuration?
    private let sourceLanguage = Locale.Language(identifier: "en")
    private let targetLanguage = Locale.Language(identifier: "zh-Hans")
    private let autoRun = CommandLine.arguments.contains("--auto")
    private let oneShot = CommandLine.arguments.contains("--once")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EasyLens · 本地翻译实验").font(.headline)
            Text("只使用 macOS Translation；首次运行可能需要确认下载语言包。")
                .font(.caption)
            TextField("English text", text: $source, axis: .vertical)
                .lineLimit(2...4)
            Button("本地英译中") { translate() }
                .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text(status).font(.caption)
            if !result.isEmpty {
                Text(result).textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 470)
        .translationTask(configuration) { session in
            let input = source
            let started = now()
            do {
                let response = try await session.translate(input)
                let elapsed = (now() - started) * 1_000
                result = response.targetText
                status = String(format: "本地翻译完成 · %.1f ms", elapsed)
                print(String(format: "LOCAL_TRANSLATION_MS=%.1f", elapsed))
                print("SOURCE_TEXT=\(input)")
                print("TARGET_TEXT=\(response.targetText)")
                print("CLOUD_LLM_CALLS=0")
                fflush(stdout)
                if oneShot { NSApp.terminate(nil) }
            } catch {
                status = "本地翻译失败：\(error.localizedDescription)"
                print("LOCAL_TRANSLATION_ERROR=\(error)")
                fflush(stdout)
                if oneShot { NSApp.terminate(nil) }
            }
        }
        .task {
            let availability = LanguageAvailability()
            let current = await availability.status(from: sourceLanguage, to: targetLanguage)
            status = "英→简中语言包状态：\(current)"
            print("EN_TO_ZH_STATUS=\(current)")
            print("NO_SCREEN_CAPTURE CLOUD_LLM_CALLS=0")
            fflush(stdout)
            if autoRun { translate() }
        }
    }

    private func translate() {
        result = ""
        status = "等待系统本地翻译…"
        if configuration == nil {
            configuration = .init(source: sourceLanguage, target: targetLanguage)
        } else {
            configuration?.invalidate()
        }
    }
}

@main
private struct LocalTranslationProbeApp: App {
    var body: some Scene {
        WindowGroup("EasyLens Local Translation") {
            TranslationProbeView()
        }
    }
}

import SwiftUI
import Translation

@MainActor
final class TranslationLanguageSetup: ObservableObject {
    enum Status: Equatable {
        case checking
        case ready
        case needsDownload
        case downloading
        case unsupported
        case failed(String)
    }

    @Published private(set) var status: Status = .checking {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    @Published var configuration: TranslationSession.Configuration?
    var onStatusChange: ((Status) -> Void)?

    private let source = Locale.Language(identifier: "en")
    private let target = Locale.Language(identifier: "zh-Hans")
    private var downloadRequested = false

    var isReady: Bool { status == .ready }

    func refresh() async {
        let availability = LanguageAvailability()
        switch await availability.status(from: source, to: target) {
        case .installed:
            downloadRequested = false
            status = .ready
        case .supported:
            status = downloadRequested ? .downloading : .needsDownload
        case .unsupported:
            downloadRequested = false
            status = .unsupported
        @unknown default:
            downloadRequested = false
            status = .unsupported
        }
    }

    func beginDownload() {
        downloadRequested = true
        status = .downloading
        var next = configuration ?? TranslationSession.Configuration(source: source, target: target)
        next.invalidate()
        configuration = next
    }

    func downloadFailed(_ error: Error) {
        downloadRequested = false
        status = .failed(error.localizedDescription)
    }

    #if DEBUG
    func previewMissingLanguages() {
        status = .needsDownload
    }
    #endif
}

@MainActor
struct TranslationLanguageSetupView: View {
    @ObservedObject var setup: TranslationLanguageSetup
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("准备英中翻译")
                .font(.title2.weight(.semibold))
            Text("EasyLens 使用 macOS 的本地翻译。首次使用需要在这台 Mac 上下载英语和简体中文语言资源。下载由 macOS 管理，完成后即可离线翻译。")
                .fixedSize(horizontal: false, vertical: true)
            Text("点击“下载语言”后，请在系统窗口中允许下载。下载可能需要几分钟；EasyLens 会自动检查是否完成。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            statusMessage
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("重新检查") { Task { await setup.refresh() } }
                Spacer()
                Button(setup.isReady ? "完成" : "稍后") { onDismiss() }
                if setup.status == .needsDownload || isFailure {
                    Button("下载语言") { setup.beginDownload() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 470)
        .translationTask(setup.configuration) { session in
            do {
                try await session.prepareTranslation()
                await setup.refresh()
            } catch {
                setup.downloadFailed(error)
            }
        }
    }

    private var isFailure: Bool {
        if case .failed = setup.status { return true }
        return false
    }

    @ViewBuilder private var statusMessage: some View {
        switch setup.status {
        case .checking:
            Label("正在检查本地语言资源…", systemImage: "arrow.triangle.2.circlepath")
        case .ready:
            Label("英语和简体中文已就绪。", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .needsDownload:
            Label("尚未安装所需语言资源。", systemImage: "arrow.down.circle")
        case .downloading:
            Label("等待系统下载并安装语言资源…", systemImage: "arrow.down.circle")
        case .unsupported:
            Label("这台 Mac 暂不支持此英中翻译组合。", systemImage: "exclamationmark.triangle")
        case .failed(let message):
            Label("准备失败：\(message)", systemImage: "exclamationmark.triangle")
        }
    }
}

import AppKit
import Foundation
import SwiftUI

enum TranslationProvider: String, CaseIterable, Identifiable {
    case local
    case deepSeek

    var id: String { rawValue }
    var title: String { self == .local ? "本地翻译" : "DeepSeek" }
}

struct DeepSeekConfiguration {
    let baseURL: URL
    let model: String
    let apiKey: String
}

enum TranslationSettingsError: LocalizedError {
    case invalidBaseURL
    case missingAPIKey
    case keyStorage(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "接口地址需为有效的 HTTPS 地址。"
        case .missingAPIKey: return "请先保存 DeepSeek API Key。"
        case .keyStorage(let detail): return "无法访问本地密钥文件（\(detail)）。"
        }
    }
}

@MainActor
final class TranslationSettings: ObservableObject {
    static let defaultBaseURL = "https://api.deepseek.com"
    static let models = ["deepseek-flash", "deepseek-v4-pro"]
    nonisolated static let defaultKeyFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".easylens", isDirectory: true)
        .appendingPathComponent("deepseek-api-key", isDirectory: false)

    @Published private(set) var provider: TranslationProvider
    @Published private(set) var baseURL: String
    @Published private(set) var model: String
    @Published private(set) var hasAPIKey: Bool
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard,
         keyFileURL: URL = TranslationSettings.defaultKeyFileURL) {
        self.defaults = defaults
        self.keyFileURL = keyFileURL
        provider = TranslationProvider(rawValue: defaults.string(forKey: "translationProvider") ?? "") ?? .local
        baseURL = defaults.string(forKey: "deepSeekBaseURL") ?? Self.defaultBaseURL
        let savedModel = defaults.string(forKey: "deepSeekModel") ?? ""
        model = Self.models.contains(savedModel) ? savedModel : Self.models[0]
        hasAPIKey = (try? Self.readAPIKey(from: keyFileURL)) != nil
    }

    private let defaults: UserDefaults
    private let keyFileURL: URL

    static func validatedBaseURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url else { return nil }
        return url
    }

    func save(provider: TranslationProvider, baseURL: String, model: String,
              newAPIKey: String) throws {
        guard let url = Self.validatedBaseURL(baseURL) else {
            throw TranslationSettingsError.invalidBaseURL
        }
        guard Self.models.contains(model) else { throw TranslationSettingsError.invalidBaseURL }
        let key = newAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { try Self.storeAPIKey(key, to: keyFileURL) }
        let available = try Self.readAPIKey(from: keyFileURL) != nil
        guard provider != .deepSeek || available else {
            throw TranslationSettingsError.missingAPIKey
        }
        self.provider = provider
        self.baseURL = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.model = model
        hasAPIKey = available
        defaults.set(provider.rawValue, forKey: "translationProvider")
        defaults.set(self.baseURL, forKey: "deepSeekBaseURL")
        defaults.set(model, forKey: "deepSeekModel")
        onChange?()
    }

    func removeAPIKey() throws {
        do {
            if FileManager.default.fileExists(atPath: keyFileURL.path) {
                try FileManager.default.removeItem(at: keyFileURL)
            }
        } catch {
            throw TranslationSettingsError.keyStorage(error.localizedDescription)
        }
        hasAPIKey = false
        if provider == .deepSeek {
            provider = .local
            defaults.set(provider.rawValue, forKey: "translationProvider")
        }
        onChange?()
    }

    func deepSeekConfiguration() throws -> DeepSeekConfiguration {
        guard let url = Self.validatedBaseURL(baseURL) else {
            throw TranslationSettingsError.invalidBaseURL
        }
        guard let key = try Self.readAPIKey(from: keyFileURL) else {
            throw TranslationSettingsError.missingAPIKey
        }
        return DeepSeekConfiguration(baseURL: url, model: model, apiKey: key)
    }

    private static func readAPIKey(from fileURL: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let key = try String(contentsOf: fileURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : key
        } catch {
            throw TranslationSettingsError.keyStorage(error.localizedDescription)
        }
    }

    private static func storeAPIKey(_ key: String, to fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try Data(key.utf8).write(to: fileURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw TranslationSettingsError.keyStorage(error.localizedDescription)
        }
    }
}

@MainActor
struct TranslationSettingsView: View {
    @ObservedObject var settings: TranslationSettings
    @State private var provider: TranslationProvider = .local
    @State private var baseURL = ""
    @State private var model = TranslationSettings.models[0]
    @State private var apiKey = ""
    @State private var message: String?
    @State private var testingConnection = false
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("翻译设置").font(.title2.weight(.semibold))
            Form {
                Picker("翻译来源", selection: $provider) {
                    ForEach(TranslationProvider.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                TextField("接口地址", text: $baseURL)
                    .textContentType(.URL)
                Picker("DeepSeek 模型", selection: $model) {
                    Text("deepseek-flash · V4.1 Flash").tag("deepseek-flash")
                    Text("deepseek-v4-pro · V4 Pro").tag("deepseek-v4-pro")
                }
                SecureField(settings.hasAPIKey ? "已保存；留空则保持原密钥" : "输入 API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text(settings.hasAPIKey ? "密钥已保存在 ~/.easylens" : "输入密钥并保存后可测试连接")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if settings.hasAPIKey {
                        Button("移除密钥") {
                            do {
                                try settings.removeAPIKey()
                                provider = settings.provider
                                message = "密钥已移除，翻译已切回本地。"
                            }
                            catch { message = error.localizedDescription }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 205)
            Text("默认使用本地翻译。选择 DeepSeek 后，待翻译文字会发送到所填接口地址；逐词和选区翻译都使用该来源。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message { Text(message).font(.callout) }
            HStack {
                Button(testingConnection ? "正在测试…" : "测试连接") {
                    testingConnection = true
                    message = nil
                    Task {
                        do {
                            let configuration = try settings.deepSeekConfiguration()
                            _ = try await DeepSeekTranslationClient().translateWord(
                                anchor: "hello", sentence: "Hello!",
                                configuration: configuration)
                            message = "DeepSeek 连接成功。"
                        } catch { message = error.localizedDescription }
                        testingConnection = false
                    }
                }
                .disabled(!settings.hasAPIKey || testingConnection)
                Spacer()
                Button("关闭") { onDismiss() }
                Button("保存") {
                    do {
                        try settings.save(provider: provider, baseURL: baseURL,
                                          model: model, newAPIKey: apiKey)
                        apiKey = ""
                        message = "设置已保存。"
                    } catch { message = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            provider = settings.provider
            baseURL = settings.baseURL
            model = settings.model
        }
    }
}

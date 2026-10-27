import AppKit
import Security
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
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "接口地址需为有效的 HTTPS 地址。"
        case .missingAPIKey: return "请先保存 DeepSeek API Key。"
        case .keychain(let status): return "无法访问钥匙串（错误码 \(status)）。"
        }
    }
}

@MainActor
final class TranslationSettings: ObservableObject {
    static let defaultBaseURL = "https://api.deepseek.com"
    static let models = ["deepseek-flash", "deepseek-v4-pro"]
    private static let keyService = "ai.nangua.EasyLens.DeepSeek"
    private static let keyAccount = "api-key"

    @Published private(set) var provider: TranslationProvider
    @Published private(set) var baseURL: String
    @Published private(set) var model: String
    @Published private(set) var hasAPIKey: Bool
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        provider = TranslationProvider(rawValue: defaults.string(forKey: "translationProvider") ?? "") ?? .local
        baseURL = defaults.string(forKey: "deepSeekBaseURL") ?? Self.defaultBaseURL
        let savedModel = defaults.string(forKey: "deepSeekModel") ?? ""
        model = Self.models.contains(savedModel) ? savedModel : Self.models[0]
        hasAPIKey = (try? Self.readAPIKey()) != nil
    }

    private let defaults: UserDefaults

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
        if !key.isEmpty { try Self.storeAPIKey(key) }
        let available = try Self.readAPIKey() != nil
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
        let status = SecItemDelete(Self.keyQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TranslationSettingsError.keychain(status)
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
        guard let key = try Self.readAPIKey() else {
            throw TranslationSettingsError.missingAPIKey
        }
        return DeepSeekConfiguration(baseURL: url, model: model, apiKey: key)
    }

    private static func keyQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keyService,
         kSecAttrAccount as String: keyAccount]
    }

    private static func readAPIKey() throws -> String? {
        var query = keyQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TranslationSettingsError.keychain(status) }
        guard let data = value as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw TranslationSettingsError.keychain(errSecDecode)
        }
        return key
    }

    private static func storeAPIKey(_ key: String) throws {
        let data = Data(key.utf8)
        let existing = SecItemCopyMatching(keyQuery() as CFDictionary, nil)
        if existing == errSecSuccess {
            let status = SecItemUpdate(keyQuery() as CFDictionary,
                                       [kSecValueData as String: data] as CFDictionary)
            guard status == errSecSuccess else { throw TranslationSettingsError.keychain(status) }
        } else if existing == errSecItemNotFound {
            var attributes = keyQuery()
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else { throw TranslationSettingsError.keychain(status) }
        } else {
            throw TranslationSettingsError.keychain(existing)
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
                    Text(settings.hasAPIKey ? "密钥已保存在此 Mac 的钥匙串" : "输入密钥并保存后可测试连接")
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

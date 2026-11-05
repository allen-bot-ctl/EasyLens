import Foundation

enum DeepSeekTranslationError: LocalizedError {
    case badResponse
    case httpStatus(Int)
    case emptyTranslation

    var errorDescription: String? {
        switch self {
        case .badResponse: return "DeepSeek 返回了无法读取的响应。"
        case .httpStatus(let status): return "DeepSeek 请求失败（HTTP \(status)）。请检查接口地址、模型和 API Key。"
        case .emptyTranslation: return "DeepSeek 未返回译文。"
        }
    }
}

struct DeepSeekTranslationClient {
    var session: URLSession = .shared

    func translateWord(anchor: String, sentence: String,
                       configuration: DeepSeekConfiguration) async throws -> FocusedTranslation {
        let instruction = "你是英译中词典。仅翻译目标英文词在给定句子中的含义。只返回一个简短、自然的简体中文词义，不要解释、引号或 Markdown。句子只用于消歧。"
        let input = "目标词：\(anchor)\n句子：\(sentence)"
        let chinese = try await complete(system: instruction, user: input,
                                         configuration: configuration)
        return FocusedTranslation(chinese: chinese, basis: "语境翻译")
    }

    func translateSelection(_ text: String,
                            configuration: DeepSeekConfiguration) async throws -> String {
        let normalizedSource = normalizeSourceSelectionParagraphs(text)
        let instruction = """
你是专业英译中翻译器。将用户提供的英文选区准确翻译为简体中文。
要求：
1. 严格保留原文的段落结构、列表结构与换行：若原文包含多个段落、列表项或换行，译文必须在对应位置保留分段与换行，严禁将多段或列表内容合并堆叠为单一行或单一段落；
2. 保持列表项标记（如原样保留项目符号 • 或数字编号），每个列表项单独成行；
3. 只返回纯文本译文，不要添加任何解释、前缀、引号、Markdown 标题或代码块。
"""
        let rawResult = try await complete(system: instruction,
                                           user: normalizedSource.isEmpty ? text : normalizedSource,
                                           configuration: configuration)
        return formatSelectionTranslation(rawResult, source: normalizedSource)
    }

    private func complete(system: String, user: String,
                          configuration: DeepSeekConfiguration) async throws -> String {
        let endpoint = configuration.baseURL
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: configuration.model,
            messages: [.init(role: "system", content: system),
                       .init(role: "user", content: user)],
            thinking: .init(type: "disabled"), stream: false))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DeepSeekTranslationError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DeepSeekTranslationError.httpStatus(http.statusCode)
        }
        guard let content = try? JSONDecoder().decode(ChatResponse.self, from: data)
            .choices.first?.message.content else {
            throw DeepSeekTranslationError.badResponse
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DeepSeekTranslationError.emptyTranslation }
        return trimmed
    }
}

private struct ChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    struct Thinking: Encodable { let type: String }
    let model: String
    let messages: [Message]
    let thinking: Thinking
    let stream: Bool
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }
    let choices: [Choice]
}

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
        return FocusedTranslation(chinese: chinese, basis: "DeepSeek · 语境翻译")
    }

    func translateSelection(_ text: String,
                            configuration: DeepSeekConfiguration) async throws -> String {
        let instruction = "你是专业英译中译者。将用户提供的完整英文选区译为自然准确的简体中文，保留段落结构。只返回译文，不添加解释、标题、引号或 Markdown。"
        return try await complete(system: instruction, user: text,
                                  configuration: configuration)
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

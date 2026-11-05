import Foundation
import XCTest
@testable import EasyLens

final class DeepSeekTranslationTests: XCTestCase {
    func testFocusedWordRequestUsesConfiguredModelAndContext() async throws {
        let session = stubSession { request in
            XCTAssertEqual(request.url?.absoluteString,
                           "https://api.deepseek.com/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let body = try self.requestBody(request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "deepseek-flash")
            XCTAssertEqual((json["thinking"] as? [String: String])?["type"], "disabled")
            XCTAssertEqual(json["stream"] as? Bool, false)
            let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
            XCTAssertTrue(messages[1]["content"]?.contains("目标词：Shanghai") == true)
            XCTAssertTrue(messages[1]["content"]?.contains("in Shanghai") == true)
            return #"{"choices":[{"message":{"content":"上海"}}]}"#
        }
        let client = DeepSeekTranslationClient(session: session)
        let result = try await client.translateWord(
            anchor: "Shanghai", sentence: "It is afternoon in Shanghai.",
            configuration: configuration)
        XCTAssertEqual(result.chinese, "上海")
    }

    func testSelectionRequestIncludesCompleteText() async throws {
        let selected = "First line.\nSecond line."
        let session = stubSession { request in
            let body = try self.requestBody(request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
            XCTAssertEqual(messages[1]["content"], selected)
            XCTAssertTrue(messages[0]["content"]?.contains("严格保留原文的段落结构") == true)
            return #"{"choices":[{"message":{"content":"第一行。\n第二行。"}}]}"#
        }
        let result = try await DeepSeekTranslationClient(session: session)
            .translateSelection(selected, configuration: configuration)
        XCTAssertEqual(result, "第一行。\n第二行。")
    }

    func testBaseURLRequiresHTTPS() async {
        await MainActor.run {
            XCTAssertNil(TranslationSettings.validatedBaseURL("http://api.deepseek.com"))
            XCTAssertNil(TranslationSettings.validatedBaseURL("https://key@example.com"))
            XCTAssertNotNil(TranslationSettings.validatedBaseURL("https://api.deepseek.com/v1"))
        }
    }

    private var configuration: DeepSeekConfiguration {
        DeepSeekConfiguration(baseURL: URL(string: "https://api.deepseek.com")!,
                              model: "deepseek-flash", apiKey: "test-key")
    }

    private func stubSession(_ handler: @escaping (URLRequest) throws -> String) -> URLSession {
        StubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func requestBody(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> String)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let body = try Self.handler?(request) ?? ""
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

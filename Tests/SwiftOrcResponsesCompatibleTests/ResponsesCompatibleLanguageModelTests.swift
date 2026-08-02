import Foundation
import SwiftOrc
import SwiftOrcHTTP
import Testing

@testable import SwiftOrcResponsesCompatible

private actor RecordingTransport: HTTPModelTransport {
    let response: HTTPModelTransportResponse
    private(set) var requests: [URLRequest] = []

    init(response: HTTPModelTransportResponse) { self.response = response }

    func send(_ request: URLRequest) async throws -> HTTPModelTransportResponse {
        requests.append(request)
        return response
    }
}

private actor StreamingTransport: HTTPStreamingModelTransport {
    let lines: [String]
    private(set) var requests: [URLRequest] = []

    init(lines: [String]) { self.lines = lines }

    func send(_ request: URLRequest) async throws -> HTTPModelTransportResponse {
        throw URLError(.unsupportedURL)
    }

    func stream(_ request: URLRequest) async throws -> HTTPModelTransportStream {
        requests.append(request)
        return HTTPModelTransportStream(
            statusCode: 200,
            headers: ["X-Request-ID": "stream-request"],
            lines: AsyncThrowingStream { continuation in
                for line in lines { continuation.yield(line) }
                continuation.finish()
            }
        )
    }
}

private let endpoint = URL(string: "https://models.example.test/v1/responses")!

private func response() -> HTTPModelTransportResponse {
    HTTPModelTransportResponse(
        data: Data(
            #"{"id":"resp-1","model":"served","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Hello"}]},{"type":"function_call","call_id":"call-1","name":"lookup","arguments":"{\"id\":1}"}],"usage":{"input_tokens":5,"output_tokens":2,"total_tokens":7}}"#
                .utf8
        ),
        statusCode: 200,
        headers: ["X-Request-ID": "request-1"]
    )
}

@Test
func encodesStatelessResponsesRequestAndDecodesOutput() async throws {
    let transport = RecordingTransport(response: response())
    let model = try ResponsesCompatibleLanguageModel(
        providerIdentifier: "openai-responses",
        endpoint: endpoint,
        modelIdentifier: "test-model",
        headers: .bearerToken("secret"),
        retryPolicy: .none,
        transport: transport
    )
    let schema = LanguageModelJSONSchema(
        name: "answer",
        schema: .objectSchema(
            properties: ["answer": .object(["type": .string("string")])],
            required: ["answer"]
        )
    )
    let tool = LanguageModelToolDefinition(
        name: "lookup",
        description: "Looks up one record.",
        parameters: .objectSchema(
            properties: ["id": .object(["type": .string("integer")])],
            required: ["id"]
        )
    )

    let result = try await model.generate(
        LanguageModelRequest(
            prompt: "Hello",
            instructions: "Be concise.",
            messages: [
                .assistant(
                    content: nil,
                    toolCalls: [
                        LanguageModelToolCall(
                            id: "previous-call",
                            name: "lookup",
                            arguments: #"{"id":0}"#
                        )
                    ]
                ),
                .tool(callID: "previous-call", content: #"{"name":"Zero"}"#),
            ],
            tools: [tool],
            toolChoice: .automatic,
            responseFormat: .jsonSchema(schema)
        )
    )

    let request = try #require(await transport.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    let body = try #require(request.httpBody)
    let json = try #require(
        try JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    #expect(json["store"] as? Bool == false)
    #expect(json["instructions"] as? String == "Be concise.")
    #expect(json["model"] as? String == "test-model")
    let input = try #require(json["input"] as? [[String: Any]])
    #expect(
        input.map { $0["type"] as? String } == [
            "message", "function_call", "function_call_output",
        ])
    let text = try #require(json["text"] as? [String: Any])
    let format = try #require(text["format"] as? [String: Any])
    #expect(format["type"] as? String == "json_schema")

    #expect(result.content == "Hello")
    #expect(
        result.toolCalls == [
            LanguageModelToolCall(id: "call-1", name: "lookup", arguments: #"{"id":1}"#)
        ])
    #expect(result.usage == LanguageModelUsage(inputTokens: 5, outputTokens: 2, totalTokens: 7))
    #expect(result.finishReason == .toolCalls)
    #expect(result.metadata["http.request-id"] == "request-1")
}

@Test
func streamsResponsesTextDeltas() async throws {
    let completed =
        #"{"type":"response.completed","response":{"id":"resp-2","model":"served","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Hello"}]}],"usage":{"input_tokens":3,"output_tokens":1,"total_tokens":4}}}"#
    let transport = StreamingTransport(lines: [
        #"data: {"type":"response.output_text.delta","delta":"Hel"}"#,
        #"data: {"type":"response.output_text.delta","delta":"lo"}"#,
        "data: \(completed)",
    ])
    let model = try ResponsesCompatibleLanguageModel(
        providerIdentifier: "responses",
        endpoint: endpoint,
        modelIdentifier: "test-model",
        retryPolicy: .none,
        transport: transport
    )

    var events: [LanguageModelStreamEvent] = []
    for try await event in model.stream(LanguageModelRequest(prompt: "Hi")) {
        events.append(event)
    }
    #expect(events.prefix(2) == [.textDelta("Hel"), .textDelta("lo")])
    guard case let .completed(result) = events.last else {
        Issue.record("Expected completion")
        return
    }
    #expect(result.content == "Hello")
    #expect(result.finishReason == .stop)
}

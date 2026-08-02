import Foundation
import SwiftOrc
import SwiftOrcHTTP
import Testing

@testable import SwiftOrcAnthropic

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

    init(lines: [String]) { self.lines = lines }

    func send(_ request: URLRequest) async throws -> HTTPModelTransportResponse {
        throw URLError(.unsupportedURL)
    }

    func stream(_ request: URLRequest) async throws -> HTTPModelTransportStream {
        HTTPModelTransportStream(
            statusCode: 200,
            headers: ["request-id": "stream-request"],
            lines: AsyncThrowingStream { continuation in
                for line in lines { continuation.yield(line) }
                continuation.finish()
            }
        )
    }
}

private func response() -> HTTPModelTransportResponse {
    HTTPModelTransportResponse(
        data: Data(
            #"{"id":"msg-1","model":"claude-test","content":[{"type":"text","text":"Hello"},{"type":"tool_use","id":"tool-1","name":"lookup","input":{"id":1}}],"stop_reason":"tool_use","usage":{"input_tokens":6,"output_tokens":3}}"#
                .utf8
        ),
        statusCode: 200,
        headers: ["request-id": "request-1"]
    )
}

@Test
func encodesMessagesRequestAndDecodesContent() async throws {
    let transport = RecordingTransport(response: response())
    let model = try AnthropicLanguageModel(
        modelIdentifier: "claude-test",
        headers: .anthropicAPIKey("secret"),
        retryPolicy: .none,
        transport: transport
    )
    let tool = LanguageModelToolDefinition(
        name: "lookup",
        description: "Looks up a record.",
        parameters: .objectSchema(
            properties: ["id": .object(["type": .string("integer")])],
            required: ["id"]
        )
    )
    let schema = LanguageModelJSONSchema(
        name: "answer",
        schema: .objectSchema(
            properties: ["answer": .object(["type": .string("string")])],
            required: ["answer"]
        )
    )

    let result = try await model.generate(
        LanguageModelRequest(
            prompt: "Hello",
            instructions: "Be concise.",
            options: LanguageModelGenerationOptions(maximumResponseTokens: 200),
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
            toolChoice: .required,
            parallelToolCalls: false,
            responseFormat: .jsonSchema(schema)
        )
    )

    let request = try #require(await transport.requests.first)
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret")
    #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    let body = try #require(request.httpBody)
    let json = try #require(
        try JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    #expect(json["system"] as? String == "Be concise.")
    #expect(json["max_tokens"] as? Int == 200)
    let messages = try #require(json["messages"] as? [[String: Any]])
    #expect(
        messages.map { $0["role"] as? String } == [
            "user", "assistant", "user",
        ])
    let choice = try #require(json["tool_choice"] as? [String: Any])
    #expect(choice["type"] as? String == "any")
    #expect(choice["disable_parallel_tool_use"] as? Bool == true)
    let output = try #require(json["output_config"] as? [String: Any])
    #expect(output["format"] != nil)

    #expect(result.content == "Hello")
    #expect(result.toolCalls.count == 1)
    #expect(result.toolCalls[0].name == "lookup")
    #expect(result.finishReason == .toolCalls)
    #expect(result.usage == LanguageModelUsage(inputTokens: 6, outputTokens: 3, totalTokens: 9))
}

@Test
func streamsAnthropicTextDeltas() async throws {
    let transport = StreamingTransport(lines: [
        #"data: {"type":"message_start","message":{"id":"msg-2","model":"claude-test","usage":{"input_tokens":4,"output_tokens":0}}}"#,
        #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}}"#,
        #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"lo"}}"#,
        #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}"#,
        #"data: {"type":"message_stop"}"#,
    ])
    let model = try AnthropicLanguageModel(
        modelIdentifier: "claude-test",
        headers: .anthropicAPIKey("secret"),
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
    #expect(result.usage == LanguageModelUsage(inputTokens: 4, outputTokens: 2, totalTokens: 6))
}

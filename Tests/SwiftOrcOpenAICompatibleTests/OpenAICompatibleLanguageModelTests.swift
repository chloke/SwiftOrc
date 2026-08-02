import Foundation
import SwiftOrc
import Testing

@testable import SwiftOrcHTTP
@testable import SwiftOrcOpenAICompatible

private enum TransportStep: Sendable {
    case response(HTTPModelTransportResponse)
    case urlError(URLError.Code)
}

private actor RecordingTransport: HTTPModelTransport {
    private var steps: [TransportStep]
    private(set) var requests: [URLRequest] = []

    init(_ steps: [TransportStep]) {
        self.steps = steps
    }

    func send(_ request: URLRequest) async throws -> HTTPModelTransportResponse {
        requests.append(request)
        guard !steps.isEmpty else {
            throw URLError(.unknown)
        }

        switch steps.removeFirst() {
        case let .response(response):
            return response
        case let .urlError(code):
            throw URLError(code)
        }
    }
}

private actor RecordingStreamingTransport: HTTPStreamingModelTransport {
    private(set) var requests: [URLRequest] = []
    let response: HTTPModelTransportStream

    init(statusCode: Int = 200, headers: [String: String] = [:], lines: [String]) {
        response = HTTPModelTransportStream(
            statusCode: statusCode,
            headers: headers,
            lines: AsyncThrowingStream { continuation in
                for line in lines {
                    continuation.yield(line)
                }
                continuation.finish()
            }
        )
    }

    func send(_ request: URLRequest) async throws -> HTTPModelTransportResponse {
        requests.append(request)
        throw URLError(.unsupportedURL)
    }

    func stream(_ request: URLRequest) async throws -> HTTPModelTransportStream {
        requests.append(request)
        return response
    }
}

private actor ProviderEventRecorder {
    private(set) var events: [HTTPModelProviderEvent] = []

    func record(_ event: HTTPModelProviderEvent) {
        events.append(event)
    }
}

private actor DelayRecorder {
    private(set) var values: [Double] = []

    func record(_ value: Double) {
        values.append(value)
    }
}

private final class OversizedResponseURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/octet-stream"]
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        let data =
            url.path == "/stream"
            ? Data("data: \(String(repeating: "x", count: 80))\n".utf8)
            : Data(repeating: 0x41, count: 80)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private let endpoint = URL(
    string: "https://models.example.test/v1/chat/completions"
)!

private func successResponse(
    content: String = "remote response"
) -> HTTPModelTransportResponse {
    HTTPModelTransportResponse(
        data: Data(
            """
            {
              "id": "response-123",
              "model": "served-model",
              "choices": [
                {
                  "index": 0,
                  "message": {
                    "role": "assistant",
                    "content": "\(content)"
                  },
                  "finish_reason": "stop"
                }
              ],
              "usage": {
                "prompt_tokens": 12,
                "completion_tokens": 4,
                "total_tokens": 16
              }
            }
            """.utf8
        ),
        statusCode: 200,
        headers: ["X-Request-ID": "request-456"]
    )
}

private func toolCallResponse() -> HTTPModelTransportResponse {
    HTTPModelTransportResponse(
        data: Data(
            #"""
            {
              "id": "tool-response",
              "model": "served-model",
              "choices": [
                {
                  "index": 0,
                  "message": {
                    "role": "assistant",
                    "content": null,
                    "tool_calls": [
                      {
                        "id": "call-add",
                        "type": "function",
                        "function": {
                          "name": "add",
                          "arguments": "{\"left\":20,\"right\":22}"
                        }
                      }
                    ]
                  },
                  "finish_reason": "tool_calls"
                }
              ]
            }
            """#.utf8
        ),
        statusCode: 200
    )
}

private struct RemoteAddArguments: Codable, Sendable {
    let left: Int
    let right: Int
}

private struct RemoteAddResult: Codable, Sendable, Equatable {
    let sum: Int
}

@Test
func encodesChatCompletionRequestsAndDecodesResponses() async throws {
    let transport = RecordingTransport([.response(successResponse())])
    let model = try OpenAICompatibleLanguageModel(
        providerIdentifier: "custom-api",
        endpoint: endpoint,
        modelIdentifier: "requested-model",
        headers: .bearerToken("secret-token"),
        additionalHeaders: ["X-Tenant": "tenant-a"],
        defaultInstructions: "Default instruction.",
        retryPolicy: .none,
        transport: transport
    )

    let response = try await model.generate(
        LanguageModelRequest(
            prompt: "Hello",
            instructions: "Request instruction.",
            options: LanguageModelGenerationOptions(
                sampling: .randomProbabilityThreshold(0.9, seed: 42),
                temperature: 0.3,
                maximumResponseTokens: 250
            )
        )
    )

    let requests = await transport.requests
    let request = try #require(requests.first)
    #expect(request.url == endpoint)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
    #expect(request.value(forHTTPHeaderField: "X-Tenant") == "tenant-a")

    let data = try #require(request.httpBody)
    let json = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(json["model"] as? String == "requested-model")
    #expect(json["temperature"] as? Double == 0.3)
    #expect(json["top_p"] as? Double == 0.9)
    #expect(json["seed"] as? Int == 42)
    #expect(json["max_completion_tokens"] as? Int == 250)

    let messages = try #require(json["messages"] as? [[String: Any]])
    #expect(messages.count == 2)
    #expect(messages[0]["role"] as? String == "developer")
    #expect(
        messages[0]["content"] as? String
            == "Default instruction.\n\nRequest instruction."
    )
    #expect(messages[1]["role"] as? String == "user")
    #expect(messages[1]["content"] as? String == "Hello")

    #expect(response.content == "remote response")
    #expect(response.provider == "custom-api")
    #expect(response.metadata["response.id"] == "response-123")
    #expect(response.metadata["response.model"] == "served-model")
    #expect(response.metadata["response.finish-reason"] == "stop")
    #expect(response.metadata["usage.input-tokens"] == "12")
    #expect(response.metadata["usage.output-tokens"] == "4")
    #expect(response.metadata["usage.total-tokens"] == "16")
    #expect(response.metadata["http.request-id"] == "request-456")
    #expect(
        response.usage
            == LanguageModelUsage(
                inputTokens: 12,
                outputTokens: 4,
                totalTokens: 16
            )
    )
    #expect(response.finishReason == .stop)
}

@Test
func streamsServerSentEventsAndReturnsTypedUsage() async throws {
    let transport = RecordingStreamingTransport(
        headers: ["X-Request-ID": "stream-request"],
        lines: [
            #"data: {"id":"stream-id","model":"served-model","choices":[{"delta":{"content":"Hel"},"finish_reason":null}]}"#,
            #"data: {"id":"stream-id","model":"served-model","choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}"#,
            "data: [DONE]",
        ]
    )
    let model = try OpenAICompatibleLanguageModel(
        providerIdentifier: "streaming-api",
        endpoint: endpoint,
        modelIdentifier: "requested-model",
        retryPolicy: .none,
        transport: transport
    )

    var events: [LanguageModelStreamEvent] = []
    for try await event in model.stream(
        LanguageModelRequest(prompt: "Hello")
    ) {
        events.append(event)
    }

    #expect(events.prefix(2) == [.textDelta("Hel"), .textDelta("lo")])
    guard case let .completed(response) = events.last else {
        Issue.record("Expected a completed streaming response")
        return
    }
    #expect(response.content == "Hello")
    #expect(response.provider == "streaming-api")
    #expect(response.finishReason == .stop)
    #expect(
        response.usage
            == LanguageModelUsage(
                inputTokens: 3,
                outputTokens: 2,
                totalTokens: 5
            )
    )
    #expect(response.metadata["response.id"] == "stream-id")
    #expect(response.metadata["http.request-id"] == "stream-request")

    let request = try #require(await transport.requests.first)
    let body = try #require(request.httpBody)
    let json = try #require(
        try JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    #expect(json["stream"] as? Bool == true)
    let options = try #require(json["stream_options"] as? [String: Any])
    #expect(options["include_usage"] as? Bool == true)
}

@Test
func encodesJSONSchemaResponseFormats() async throws {
    let transport = RecordingTransport([.response(successResponse())])
    let model = try OpenAICompatibleLanguageModel(
        providerIdentifier: "remote",
        endpoint: endpoint,
        modelIdentifier: "model",
        retryPolicy: .none,
        transport: transport
    )
    let schema = LanguageModelJSONSchema(
        name: "character_profile",
        description: "A character personality.",
        schema: .objectSchema(
            properties: [
                "name": .object(["type": .string("string")])
            ],
            required: ["name"]
        )
    )

    _ = try await model.generate(
        LanguageModelRequest(
            prompt: "Create a character",
            responseFormat: .jsonSchema(schema)
        )
    )

    let requests = await transport.requests
    let data = try #require(requests.first?.httpBody)
    let json = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let responseFormat = try #require(
        json["response_format"] as? [String: Any]
    )
    #expect(responseFormat["type"] as? String == "json_schema")
    let jsonSchema = try #require(
        responseFormat["json_schema"] as? [String: Any]
    )
    #expect(jsonSchema["name"] as? String == "character_profile")
    #expect(jsonSchema["description"] as? String == "A character personality.")
    #expect(jsonSchema["strict"] as? Bool == true)
    let encodedSchema = try #require(
        jsonSchema["schema"] as? [String: Any]
    )
    #expect(encodedSchema["type"] as? String == "object")
    #expect(encodedSchema["additionalProperties"] as? Bool == false)
}

@Test
func executesAnOpenAICompatibleToolCallingLoop() async throws {
    let transport = RecordingTransport([
        .response(toolCallResponse()),
        .response(successResponse(content: "The result is 42.")),
    ])
    let remote = try OpenAICompatibleLanguageModel(
        providerIdentifier: "remote",
        endpoint: endpoint,
        modelIdentifier: "model",
        retryPolicy: .none,
        transport: transport
    )
    let add = ClosureLanguageModelTool<RemoteAddArguments, RemoteAddResult>(
        definition: LanguageModelToolDefinition(
            name: "add",
            description: "Adds two integers.",
            parameters: .objectSchema(
                properties: [
                    "left": .object(["type": .string("integer")]),
                    "right": .object(["type": .string("integer")]),
                ],
                required: ["left", "right"]
            )
        ),
        call: { arguments in
            RemoteAddResult(sum: arguments.left + arguments.right)
        }
    )
    let model = try ToolCallingLanguageModel(
        model: remote,
        tools: [add]
    )

    let response = try await model.generate(
        LanguageModelRequest(
            prompt: "What is 20 plus 22?",
            toolChoice: .required,
            parallelToolCalls: false
        )
    )

    #expect(response.content == "The result is 42.")
    #expect(response.toolExecutionReport?.modelCalls == 2)
    #expect(response.toolExecutionReport?.executions.map(\.tool) == ["add"])

    let requests = await transport.requests
    #expect(requests.count == 2)
    let firstData = try #require(requests[0].httpBody)
    let firstJSON = try #require(
        try JSONSerialization.jsonObject(with: firstData) as? [String: Any]
    )
    #expect(firstJSON["tool_choice"] as? String == "required")
    #expect(firstJSON["parallel_tool_calls"] as? Bool == false)
    let tools = try #require(firstJSON["tools"] as? [[String: Any]])
    let function = try #require(tools[0]["function"] as? [String: Any])
    #expect(tools[0]["type"] as? String == "function")
    #expect(function["name"] as? String == "add")
    #expect(function["strict"] as? Bool == true)
    let parameters = try #require(
        function["parameters"] as? [String: Any]
    )
    #expect(parameters["additionalProperties"] as? Bool == false)

    let secondData = try #require(requests[1].httpBody)
    let secondJSON = try #require(
        try JSONSerialization.jsonObject(with: secondData) as? [String: Any]
    )
    #expect(secondJSON["tool_choice"] as? String == "auto")
    let messages = try #require(
        secondJSON["messages"] as? [[String: Any]]
    )
    #expect(messages.count == 3)
    #expect(messages[0]["role"] as? String == "user")
    #expect(messages[1]["role"] as? String == "assistant")
    let calls = try #require(
        messages[1]["tool_calls"] as? [[String: Any]]
    )
    #expect(calls[0]["id"] as? String == "call-add")
    #expect(messages[2]["role"] as? String == "tool")
    #expect(messages[2]["tool_call_id"] as? String == "call-add")
    let output = try #require(messages[2]["content"] as? String)
    #expect(
        try JSONDecoder().decode(
            RemoteAddResult.self,
            from: Data(output.utf8)
        ) == RemoteAddResult(sum: 42)
    )
}

@Test
func retriesTransientStatusUsingRetryAfter() async throws {
    let overloaded = HTTPModelTransportResponse(
        data: Data(
            """
            {"error":{"message":"busy","type":"server_error","code":null}}
            """.utf8
        ),
        statusCode: 503,
        headers: ["Retry-After": "0.25"]
    )
    let transport = RecordingTransport([
        .response(overloaded),
        .response(successResponse()),
    ])
    let events = ProviderEventRecorder()
    let delays = DelayRecorder()
    let model = try OpenAICompatibleLanguageModel(
        providerIdentifier: "remote",
        endpoint: endpoint,
        modelIdentifier: "model",
        retryPolicy: HTTPModelRetryPolicy(
            maximumAttempts: 2,
            baseDelaySeconds: 0.1,
            maximumDelaySeconds: 1
        ),
        transport: transport,
        onEvent: { event in await events.record(event) },
        sleep: { delay in await delays.record(delay) }
    )

    let response = try await model.generate(
        LanguageModelRequest(prompt: "Hello")
    )

    #expect(response.content == "remote response")
    #expect(await transport.requests.count == 2)
    #expect(await delays.values == [0.25])
    #expect(
        await events.events == [
            .requestStarted(provider: "remote", attempt: 1),
            .requestFailed(
                provider: "remote",
                statusCode: 503,
                attempt: 1,
                retryable: true
            ),
            .retryScheduled(
                provider: "remote",
                nextAttempt: 2,
                delaySeconds: 0.25,
                reason: .statusCode(503)
            ),
            .requestStarted(provider: "remote", attempt: 2),
            .requestSucceeded(
                provider: "remote",
                statusCode: 200,
                attempt: 2
            ),
        ]
    )
}

@Test
func retriesTransientURLSessionFailures() async throws {
    let transport = RecordingTransport([
        .urlError(.timedOut),
        .response(successResponse()),
    ])
    let delays = DelayRecorder()
    let model = try OpenAICompatibleLanguageModel(
        providerIdentifier: "remote",
        endpoint: endpoint,
        modelIdentifier: "model",
        retryPolicy: HTTPModelRetryPolicy(
            maximumAttempts: 2,
            baseDelaySeconds: 0.2,
            maximumDelaySeconds: 1
        ),
        transport: transport,
        sleep: { delay in await delays.record(delay) }
    )

    let response = try await model.generate(
        LanguageModelRequest(prompt: "Hello")
    )

    #expect(response.content == "remote response")
    #expect(await transport.requests.count == 2)
    #expect(await delays.values == [0.2])
}

@Test
func classifiesPermanentURLSessionFailuresWithoutRetrying() async throws {
    let transport = RecordingTransport([
        .urlError(.serverCertificateUntrusted)
    ])
    let model = try OpenAICompatibleLanguageModel(
        providerIdentifier: "remote",
        endpoint: endpoint,
        modelIdentifier: "model",
        transport: transport,
        sleep: { _ in Issue.record("A permanent transport failure must not sleep") }
    )

    do {
        _ = try await model.generate(LanguageModelRequest(prompt: "Hello"))
        Issue.record("Expected the provider request to fail")
    } catch let error as OpenAICompatibleLanguageModelError {
        guard case let .transport(_, retryable, attempts) = error else {
            Issue.record("Expected a structured transport error")
            return
        }
        #expect(!retryable)
        #expect(attempts == 1)
        #expect(!error.isRetryable)
    }
    #expect(await transport.requests.count == 1)
}

@Test
func doesNotRetryPermanentHTTPFailures() async throws {
    let unauthorized = HTTPModelTransportResponse(
        data: Data(
            """
            {"error":{"message":"invalid key","type":"authentication_error","code":"invalid_api_key"}}
            """.utf8
        ),
        statusCode: 401
    )
    let transport = RecordingTransport([.response(unauthorized)])
    let model = try OpenAICompatibleLanguageModel(
        providerIdentifier: "remote",
        endpoint: endpoint,
        modelIdentifier: "model",
        transport: transport,
        sleep: { _ in Issue.record("A permanent failure must not sleep") }
    )

    do {
        _ = try await model.generate(LanguageModelRequest(prompt: "Hello"))
        Issue.record("Expected the provider request to fail")
    } catch let error as OpenAICompatibleLanguageModelError {
        guard
            case let .httpStatus(
                statusCode,
                code,
                _,
                message,
                retryable,
                attempts
            ) = error
        else {
            Issue.record("Expected a structured HTTP status error")
            return
        }
        #expect(statusCode == 401)
        #expect(code == "invalid_api_key")
        #expect(message == nil)
        #expect(!retryable)
        #expect(attempts == 1)
    }
    #expect(await transport.requests.count == 1)
}

@Test
func doesNotRetryInsufficientQuotaResponses() async throws {
    let quota = HTTPModelTransportResponse(
        data: Data(
            """
            {"error":{"message":"quota exceeded","type":"insufficient_quota","code":"insufficient_quota"}}
            """.utf8
        ),
        statusCode: 429
    )
    let transport = RecordingTransport([.response(quota)])
    let model = try OpenAICompatibleLanguageModel(
        providerIdentifier: "remote",
        endpoint: endpoint,
        modelIdentifier: "model",
        transport: transport,
        sleep: { _ in Issue.record("Quota exhaustion must not sleep") }
    )

    do {
        _ = try await model.generate(LanguageModelRequest(prompt: "Hello"))
        Issue.record("Expected the provider request to fail")
    } catch let error as OpenAICompatibleLanguageModelError {
        #expect(!error.isRetryable)
    }
    #expect(await transport.requests.count == 1)
}

@Test
func rejectsUnsupportedSamplingBeforeUsingTransport() async throws {
    let transport = RecordingTransport([.response(successResponse())])
    let model = try OpenAICompatibleLanguageModel(
        providerIdentifier: "remote",
        endpoint: endpoint,
        modelIdentifier: "model",
        transport: transport
    )

    do {
        _ = try await model.generate(
            LanguageModelRequest(
                prompt: "Hello",
                options: LanguageModelGenerationOptions(
                    sampling: .randomTopK(10)
                )
            )
        )
        Issue.record("Expected unsupported sampling to be rejected")
    } catch let error as OpenAICompatibleLanguageModelError {
        guard case .unsupportedSampling = error else {
            Issue.record("Expected an unsupported sampling error")
            return
        }
    }
    #expect(await transport.requests.isEmpty)
}

@Test
func rejectsMissingBearerTokensBeforeUsingTransport() async throws {
    let transport = RecordingTransport([.response(successResponse())])
    let model = try OpenAICompatibleLanguageModel(
        providerIdentifier: "remote",
        endpoint: endpoint,
        modelIdentifier: "model",
        headers: .bearerToken(""),
        transport: transport
    )

    do {
        _ = try await model.generate(LanguageModelRequest(prompt: "Hello"))
        Issue.record("Expected the missing credential to fail")
    } catch let error as OpenAICompatibleLanguageModelError {
        guard case .requestEncoding = error else {
            Issue.record("Expected a request encoding error")
            return
        }
    }
    #expect(await transport.requests.isEmpty)
}

@Test
func remoteAdapterFailuresAdvanceTheLanguageModelRouter() async throws {
    let unauthorized = HTTPModelTransportResponse(
        data: Data(
            """
            {"error":{"message":"invalid key","type":"authentication_error","code":"invalid_api_key"}}
            """.utf8
        ),
        statusCode: 401
    )
    let unavailable = HTTPModelTransportResponse(
        data: Data(
            """
            {"error":{"message":"unavailable","type":"server_error","code":null}}
            """.utf8
        ),
        statusCode: 503
    )
    let primary = try OpenAICompatibleLanguageModel(
        providerIdentifier: "primary",
        endpoint: endpoint,
        modelIdentifier: "model",
        retryPolicy: .none,
        transport: RecordingTransport([.response(unauthorized)])
    )
    let secondary = try OpenAICompatibleLanguageModel(
        providerIdentifier: "secondary",
        endpoint: endpoint,
        modelIdentifier: "model",
        retryPolicy: .none,
        transport: RecordingTransport([.response(unavailable)])
    )
    let onDevice = ClosureLanguageModel { _ in
        LanguageModelResponse(content: "local response")
    }
    let router = try LanguageModelRouter(routes: [
        LanguageModelRoute(provider: "primary", model: primary),
        LanguageModelRoute(provider: "secondary", model: secondary),
        LanguageModelRoute(
            provider: "local",
            kind: .onDevice,
            model: onDevice
        ),
        LanguageModelRoute(
            provider: "static",
            kind: .staticFallback,
            model: StaticLanguageModel(content: "static response")
        ),
    ])

    let response = try await router.generate(
        LanguageModelRequest(
            prompt: "Hello",
            routingPolicy: .remoteThenOnDeviceAndStatic
        )
    )

    #expect(response.content == "local response")
    #expect(response.provider == "local")
    #expect(response.routingReport?.selectedKind == .onDevice)
    #expect(
        response.routingReport?.attemptedProviders
            == ["primary", "secondary", "local"]
    )
}

@Test
func encodesMultipartTextAndImageInput() async throws {
    let transport = RecordingTransport([.response(successResponse())])
    let model = try OpenAICompatibleLanguageModel(
        providerIdentifier: "vision-provider",
        endpoint: endpoint,
        modelIdentifier: "vision-model",
        retryPolicy: .none,
        transport: transport
    )
    let imageBytes = Data([0x01, 0x02, 0x03])

    _ = try await model.generate(
        LanguageModelRequest(
            prompt: "Check this image for child-safe content.",
            input: [
                .image(
                    LanguageModelImage(
                        source: .data(
                            imageBytes,
                            mediaType: "image/png"
                        ),
                        detail: .high
                    )
                ),
                .text("Return only the requested safety fields."),
            ]
        )
    )

    let request = try #require(await transport.requests.first)
    let body = try #require(request.httpBody)
    let json = try #require(
        try JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    let messages = try #require(json["messages"] as? [[String: Any]])
    let content = try #require(messages[0]["content"] as? [[String: Any]])

    #expect(content.count == 3)
    #expect(content[0]["type"] as? String == "text")
    #expect(
        content[0]["text"] as? String
            == "Check this image for child-safe content."
    )
    #expect(content[1]["type"] as? String == "image_url")
    let imageURL = try #require(
        content[1]["image_url"] as? [String: Any]
    )
    #expect(
        imageURL["url"] as? String
            == "data:image/png;base64,\(imageBytes.base64EncodedString())"
    )
    #expect(imageURL["detail"] as? String == "high")
    #expect(content[2]["type"] as? String == "text")
}

@Test
func rejectsOversizedInlineImagesBeforeUsingTransport() async throws {
    let transport = RecordingTransport([.response(successResponse())])
    let model = try OpenAICompatibleLanguageModel(
        providerIdentifier: "vision-provider",
        endpoint: endpoint,
        modelIdentifier: "vision-model",
        maximumInlineImageBytes: 2,
        retryPolicy: .none,
        transport: transport
    )

    do {
        _ = try await model.generate(
            LanguageModelRequest(
                prompt: "Inspect this.",
                input: [
                    .image(
                        LanguageModelImage(
                            source: .data(
                                Data([1, 2, 3]),
                                mediaType: "image/png"
                            )
                        )
                    )
                ]
            )
        )
        Issue.record("Expected the inline image limit to fail")
    } catch let error as OpenAICompatibleLanguageModelError {
        #expect(error == .inlineImageTooLarge(byteCount: 3, maximum: 2))
    }
    #expect(await transport.requests.isEmpty)
}

@Test
func rejectsCleartextEndpointsUnlessTheyAreExplicitLoopback() throws {
    for value in [
        "http://models.example.test/v1/chat/completions",
        "http://127.0.0.1:1234/v1/chat/completions",
    ] {
        do {
            _ = try OpenAICompatibleLanguageModel(
                providerIdentifier: "insecure",
                endpoint: try #require(URL(string: value)),
                modelIdentifier: "model"
            )
            Issue.record("Expected cleartext HTTP to be rejected by default")
        } catch let error as OpenAICompatibleConfigurationError {
            #expect(error == .insecureEndpoint)
        }
    }

    _ = try OpenAICompatibleLanguageModel(
        providerIdentifier: "local",
        endpoint: try #require(
            URL(string: "http://127.0.0.1:1234/v1/chat/completions")
        ),
        modelIdentifier: "model",
        endpointSecurityPolicy: .allowInsecureLoopback
    )

    do {
        _ = try OpenAICompatibleLanguageModel(
            providerIdentifier: "not-local",
            endpoint: try #require(
                URL(string: "http://models.example.test/v1/chat/completions")
            ),
            modelIdentifier: "model",
            endpointSecurityPolicy: .allowInsecureLoopback
        )
        Issue.record("Expected the loopback policy to reject a remote host")
    } catch let error as OpenAICompatibleConfigurationError {
        #expect(error == .insecureEndpoint)
    }
}

@Test
func rejectsEndpointCredentialsAndFragments() throws {
    for value in [
        "https://user:password@models.example.test/v1/chat/completions",
        "https://models.example.test/v1/chat/completions#secret",
    ] {
        do {
            _ = try OpenAICompatibleLanguageModel(
                providerIdentifier: "invalid",
                endpoint: try #require(URL(string: value)),
                modelIdentifier: "model"
            )
            Issue.record("Expected endpoint user information to be rejected")
        } catch let error as OpenAICompatibleConfigurationError {
            #expect(error == .invalidEndpoint)
        }
    }
}

@Test
func secureTransportConfigurationIsIsolatedAndRedirectsStayOnOrigin() {
    let configuration = URLSessionHTTPModelTransport.makeSecureConfiguration()
    #expect(configuration.urlCache == nil)
    #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #expect(configuration.httpCookieStorage == nil)
    #expect(!configuration.httpShouldSetCookies)
    #expect(configuration.urlCredentialStorage == nil)

    let original = URL(string: "https://models.example.test/v1/chat")!
    #expect(
        SameOriginRedirectDelegate.haveSameOrigin(
            original,
            URL(string: "https://models.example.test:443/v2/chat")!
        )
    )
    #expect(
        !SameOriginRedirectDelegate.haveSameOrigin(
            original,
            URL(string: "https://attacker.example.test/v1/chat")!
        )
    )
    #expect(
        !SameOriginRedirectDelegate.haveSameOrigin(
            original,
            URL(string: "http://models.example.test/v1/chat")!
        )
    )
}

@Test
func rejectsOversizedEncodedRequestsBeforeUsingTransport() async throws {
    let transport = RecordingTransport([.response(successResponse())])
    let model = try OpenAICompatibleLanguageModel(
        providerIdentifier: "bounded",
        endpoint: endpoint,
        modelIdentifier: "model",
        resourceLimits: HTTPModelResourceLimits(maximumRequestBodyBytes: 32),
        retryPolicy: .none,
        transport: transport
    )

    do {
        _ = try await model.generate(
            LanguageModelRequest(prompt: String(repeating: "x", count: 100))
        )
        Issue.record("Expected the encoded request limit to fail")
    } catch let error as OpenAICompatibleLanguageModelError {
        #expect(error == .requestBodyTooLarge(maximum: 32))
    }
    #expect(await transport.requests.isEmpty)
}

@Test
func rejectsOversizedResponsesFromCustomTransports() async throws {
    let transport = RecordingTransport([.response(successResponse())])
    let model = try OpenAICompatibleLanguageModel(
        providerIdentifier: "bounded",
        endpoint: endpoint,
        modelIdentifier: "model",
        resourceLimits: HTTPModelResourceLimits(maximumResponseBodyBytes: 16),
        retryPolicy: .none,
        transport: transport
    )

    do {
        _ = try await model.generate(LanguageModelRequest(prompt: "Hello"))
        Issue.record("Expected the response limit to fail")
    } catch let error as OpenAICompatibleLanguageModelError {
        #expect(error == .responseBodyTooLarge(maximum: 16))
    }
}

@Test
func rejectsOversizedEventsFromCustomStreamingTransports() async throws {
    let transport = RecordingStreamingTransport(
        lines: ["data: \(String(repeating: "x", count: 80))"]
    )
    let model = try OpenAICompatibleLanguageModel(
        providerIdentifier: "bounded",
        endpoint: endpoint,
        modelIdentifier: "model",
        resourceLimits: HTTPModelResourceLimits(
            maximumStreamingEventBytes: 32,
            maximumStreamingResponseBytes: 128
        ),
        retryPolicy: .none,
        transport: transport
    )

    do {
        for try await _ in model.stream(
            LanguageModelRequest(prompt: "Hello")
        ) {}
        Issue.record("Expected the streaming event limit to fail")
    } catch let error as OpenAICompatibleLanguageModelError {
        #expect(error == .streamingEventTooLarge(maximum: 32))
    }
}

@Test
func rejectsControlCharactersInBearerTokens() async throws {
    do {
        _ = try await HTTPRequestHeaders.bearerToken("token\r\ninjected")
            .values()
        Issue.record("Expected the invalid bearer token to fail")
    } catch let error as HTTPRequestHeadersError {
        #expect(error == .invalidBearerToken)
    }
}

@Test
func bundledTransportEnforcesBodyAndStreamingLineLimitsWhileReading() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OversizedResponseURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let limits = HTTPModelResourceLimits(
        maximumResponseBodyBytes: 16,
        maximumStreamingEventBytes: 16,
        maximumStreamingResponseBytes: 128
    )
    let transport = URLSessionHTTPModelTransport(
        session: session,
        limits: limits
    )

    do {
        _ = try await transport.send(
            URLRequest(url: URL(string: "https://models.example.test/body")!)
        )
        Issue.record("Expected the transport body limit to fail")
    } catch let error as HTTPModelTransportError {
        #expect(error == .responseBodyTooLarge(maximum: 16))
    }

    let stream = try await transport.stream(
        URLRequest(url: URL(string: "https://models.example.test/stream")!)
    )
    do {
        for try await _ in stream.lines {}
        Issue.record("Expected the transport streaming line limit to fail")
    } catch let error as HTTPModelTransportError {
        #expect(error == .streamingEventTooLarge(maximum: 16))
    }
}

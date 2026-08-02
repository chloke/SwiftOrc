import Foundation
import SwiftOrc
import SwiftOrcHTTP

public enum AnthropicRequestHeadersError: Error, Sendable, Equatable {
    case missingAPIKey
    case invalidAPIKey
}

public extension HTTPRequestHeaders {
    /// Resolves an Anthropic API key at request time.
    static func anthropicAPIKey(_ key: String) -> HTTPRequestHeaders {
        HTTPRequestHeaders { try anthropicHeaders(key) }
    }

    /// Resolves an Anthropic API key from Keychain or another app-owned store.
    static func anthropicAPIKey(
        resolve: @escaping @Sendable () async throws -> String
    ) -> HTTPRequestHeaders {
        HTTPRequestHeaders { try anthropicHeaders(try await resolve()) }
    }
}

private func anthropicHeaders(_ key: String) throws -> [String: String] {
    guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AnthropicRequestHeadersError.missingAPIKey
    }
    guard !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
        throw AnthropicRequestHeadersError.invalidAPIKey
    }
    return ["x-api-key": key]
}

public enum AnthropicConfigurationError: Error, Sendable, Equatable {
    case emptyProviderIdentifier
    case emptyModelIdentifier
    case emptyAPIVersion
    case invalidEndpoint
    case insecureEndpoint
    case invalidRequestTimeout
    case invalidDefaultMaximumResponseTokens
    case invalidRetryPolicy
    case invalidMaximumInlineImageBytes
    case invalidResourceLimits
}

public enum AnthropicLanguageModelError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case unsupportedSampling(LanguageModelSampling)
    case invalidGenerationOption(String)
    case invalidImageMediaType(String)
    case invalidImageURL
    case inlineImageTooLarge(byteCount: Int, maximum: Int)
    case invalidToolArguments(tool: String)
    case requestBodyTooLarge(maximum: Int)
    case responseBodyTooLarge(maximum: Int)
    case streamingEventTooLarge(maximum: Int)
    case streamingResponseTooLarge(maximum: Int)
    case tooManyStreamingEvents(maximum: Int)
    case streamingTransportUnavailable
    case unsupportedStreamingFeature(String)
    case requestEncoding(WorkflowFailure)
    case transport(failure: WorkflowFailure, retryable: Bool, attempts: Int)
    case httpStatus(
        statusCode: Int,
        type: String?,
        message: String?,
        retryable: Bool,
        attempts: Int
    )
    case invalidResponse(String)

    public var isRetryable: Bool {
        switch self {
        case let .httpStatus(_, _, _, retryable, _): retryable
        case let .transport(_, retryable, _): retryable
        default: false
        }
    }

    public var description: String {
        switch self {
        case .unsupportedSampling:
            "The requested sampling mode is not supported by Anthropic Messages."
        case let .invalidGenerationOption(option):
            "The generation option '\(option)' is invalid."
        case let .invalidImageMediaType(mediaType):
            "The image media type '\(mediaType)' is invalid."
        case .invalidImageURL:
            "The image URL must be an absolute HTTP or HTTPS URL."
        case let .inlineImageTooLarge(byteCount, maximum):
            "The inline image contains \(byteCount) bytes; the configured maximum is \(maximum)."
        case let .invalidToolArguments(tool):
            "The recorded arguments for tool '\(tool)' are not valid JSON."
        case let .requestBodyTooLarge(maximum):
            "The encoded request exceeds the configured \(maximum)-byte limit."
        case let .responseBodyTooLarge(maximum):
            "The provider response exceeds the configured \(maximum)-byte limit."
        case let .streamingEventTooLarge(maximum):
            "A streaming event exceeds the configured \(maximum)-byte limit."
        case let .streamingResponseTooLarge(maximum):
            "The streaming response exceeds the configured \(maximum)-byte limit."
        case let .tooManyStreamingEvents(maximum):
            "The streaming response exceeds the configured \(maximum)-event limit."
        case .streamingTransportUnavailable:
            "The configured HTTP transport does not support streaming."
        case let .unsupportedStreamingFeature(feature):
            "Streaming does not support the requested feature '\(feature)'."
        case let .requestEncoding(failure):
            "The model request could not be encoded: \(failure.message)"
        case let .transport(failure, _, attempts):
            "The HTTP transport failed after \(attempts) attempt(s): \(failure.message)"
        case let .httpStatus(statusCode, _, message, _, attempts):
            "Anthropic returned HTTP \(statusCode) after \(attempts) attempt(s)\(message.map { ": \($0)" } ?? "")"
        case let .invalidResponse(reason):
            "Anthropic returned an invalid response: \(reason)"
        }
    }
}

/// A native adapter for Anthropic's stateless Messages API.
public struct AnthropicLanguageModel: StreamingWorkflowLanguageModel {
    public static let messagesEndpoint = URL(
        string: "https://api.anthropic.com/v1/messages"
    )!

    public let providerIdentifier: String
    public let endpoint: URL
    public let modelIdentifier: String
    public let apiVersion: String
    public let defaultMaximumResponseTokens: Int
    public let retryPolicy: HTTPModelRetryPolicy
    public let maximumInlineImageBytes: Int
    public let includesProviderErrorMessages: Bool
    public let endpointSecurityPolicy: HTTPModelEndpointSecurityPolicy
    public let resourceLimits: HTTPModelResourceLimits

    private let headers: HTTPRequestHeaders
    private let additionalHeaders: [String: String]
    private let defaultInstructions: String?
    private let requestTimeoutSeconds: Double
    private let transport: any HTTPModelTransport
    private let onEvent: HTTPModelProviderEventHandler?
    private let sleep: @Sendable (Double) async throws -> Void

    public init(
        providerIdentifier: String = "anthropic",
        endpoint: URL = Self.messagesEndpoint,
        modelIdentifier: String,
        headers: HTTPRequestHeaders,
        apiVersion: String = "2023-06-01",
        additionalHeaders: [String: String] = [:],
        defaultInstructions: String? = nil,
        defaultMaximumResponseTokens: Int = 4_096,
        requestTimeoutSeconds: Double = 60,
        maximumInlineImageBytes: Int = 20 * 1_024 * 1_024,
        endpointSecurityPolicy: HTTPModelEndpointSecurityPolicy = .httpsOnly,
        resourceLimits: HTTPModelResourceLimits = .default,
        includesProviderErrorMessages: Bool = false,
        retryPolicy: HTTPModelRetryPolicy = HTTPModelRetryPolicy(),
        transport: (any HTTPModelTransport)? = nil,
        onEvent: HTTPModelProviderEventHandler? = nil,
        sleep: @escaping @Sendable (Double) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) throws {
        guard !Self.trimmed(providerIdentifier).isEmpty else {
            throw AnthropicConfigurationError.emptyProviderIdentifier
        }
        guard !Self.trimmed(modelIdentifier).isEmpty else {
            throw AnthropicConfigurationError.emptyModelIdentifier
        }
        guard !Self.trimmed(apiVersion).isEmpty else {
            throw AnthropicConfigurationError.emptyAPIVersion
        }
        guard Self.isStructurallyValid(endpoint) else {
            throw AnthropicConfigurationError.invalidEndpoint
        }
        guard Self.isAllowed(endpoint, under: endpointSecurityPolicy) else {
            throw AnthropicConfigurationError.insecureEndpoint
        }
        guard requestTimeoutSeconds > 0 else {
            throw AnthropicConfigurationError.invalidRequestTimeout
        }
        guard defaultMaximumResponseTokens > 0 else {
            throw AnthropicConfigurationError.invalidDefaultMaximumResponseTokens
        }
        guard maximumInlineImageBytes > 0 else {
            throw AnthropicConfigurationError.invalidMaximumInlineImageBytes
        }
        guard Self.isValid(resourceLimits) else {
            throw AnthropicConfigurationError.invalidResourceLimits
        }
        guard retryPolicy.maximumAttempts >= 1,
            retryPolicy.baseDelaySeconds >= 0,
            retryPolicy.maximumDelaySeconds >= retryPolicy.baseDelaySeconds
        else {
            throw AnthropicConfigurationError.invalidRetryPolicy
        }

        self.providerIdentifier = providerIdentifier
        self.endpoint = endpoint
        self.modelIdentifier = modelIdentifier
        self.headers = headers
        self.apiVersion = apiVersion
        self.additionalHeaders = additionalHeaders
        self.defaultInstructions = defaultInstructions
        self.defaultMaximumResponseTokens = defaultMaximumResponseTokens
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.maximumInlineImageBytes = maximumInlineImageBytes
        self.endpointSecurityPolicy = endpointSecurityPolicy
        self.resourceLimits = resourceLimits
        self.includesProviderErrorMessages = includesProviderErrorMessages
        self.retryPolicy = retryPolicy
        self.transport = transport ?? URLSessionHTTPModelTransport(limits: resourceLimits)
        self.onEvent = onEvent
        self.sleep = sleep
    }

    public func generate(
        _ request: LanguageModelRequest
    ) async throws -> LanguageModelResponse {
        let body = try makeBody(for: request)
        var attempt = 1
        while true {
            try Task.checkCancellation()
            await onEvent?(.requestStarted(provider: providerIdentifier, attempt: attempt))
            let urlRequest: URLRequest
            do {
                urlRequest = try await makeURLRequest(body: body)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AnthropicLanguageModelError {
                throw error
            } catch {
                throw AnthropicLanguageModelError.requestEncoding(
                    WorkflowFailure(error: error)
                )
            }
            do {
                let response = try await transport.send(urlRequest)
                try validate(response)
                if (200...299).contains(response.statusCode) {
                    let result = try decode(response)
                    await onEvent?(
                        .requestSucceeded(
                            provider: providerIdentifier,
                            statusCode: response.statusCode,
                            attempt: attempt
                        )
                    )
                    return result
                }

                let error = makeHTTPError(response, attempts: attempt)
                await onEvent?(
                    .requestFailed(
                        provider: providerIdentifier,
                        statusCode: response.statusCode,
                        attempt: attempt,
                        retryable: error.isRetryable
                    )
                )
                guard error.isRetryable, attempt < retryPolicy.maximumAttempts else {
                    throw error
                }
                let delay = retryDelay(response, failedAttempt: attempt)
                attempt += 1
                await onEvent?(
                    .retryScheduled(
                        provider: providerIdentifier,
                        nextAttempt: attempt,
                        delaySeconds: delay,
                        reason: .statusCode(response.statusCode)
                    )
                )
                try await sleep(delay)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AnthropicLanguageModelError {
                throw error
            } catch {
                let retryable = Self.isRetryableTransportError(error)
                await onEvent?(
                    .requestFailed(
                        provider: providerIdentifier,
                        statusCode: nil,
                        attempt: attempt,
                        retryable: retryable
                    )
                )
                guard retryable, attempt < retryPolicy.maximumAttempts else {
                    throw AnthropicLanguageModelError.transport(
                        failure: WorkflowFailure(error: error),
                        retryable: retryable,
                        attempts: attempt
                    )
                }
                let delay = exponentialDelay(after: attempt)
                attempt += 1
                await onEvent?(
                    .retryScheduled(
                        provider: providerIdentifier,
                        nextAttempt: attempt,
                        delaySeconds: delay,
                        reason: .transport
                    )
                )
                try await sleep(delay)
            }
        }
    }

    public func stream(
        _ request: LanguageModelRequest
    ) -> AsyncThrowingStream<LanguageModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performStream(request, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func performStream(
        _ request: LanguageModelRequest,
        continuation: AsyncThrowingStream<
            LanguageModelStreamEvent,
            any Error
        >.Continuation
    ) async throws {
        guard
            request.tools.isEmpty
                || request.toolChoice == LanguageModelToolChoice.none
        else {
            throw
                AnthropicLanguageModelError
                .unsupportedStreamingFeature("tool-calling")
        }
        guard let transport = transport as? any HTTPStreamingModelTransport else {
            throw AnthropicLanguageModelError.streamingTransportUnavailable
        }
        await onEvent?(.requestStarted(provider: providerIdentifier, attempt: 1))
        let stream = try await transport.stream(
            try await makeURLRequest(body: try makeBody(for: request, streaming: true))
        )
        guard (200...299).contains(stream.statusCode) else {
            throw AnthropicLanguageModelError.httpStatus(
                statusCode: stream.statusCode,
                type: nil,
                message: nil,
                retryable: retryPolicy.retryableStatusCodes.contains(stream.statusCode),
                attempts: 1
            )
        }

        var content = ""
        var responseID: String?
        var responseModel: String?
        var inputTokens: Int?
        var outputTokens: Int?
        var stopReason: String?
        var streamedBytes = 0
        var streamedEvents = 0
        for try await line in stream.lines {
            try Task.checkCancellation()
            let lineBytes = line.utf8.count
            guard lineBytes <= resourceLimits.maximumStreamingEventBytes else {
                throw AnthropicLanguageModelError.streamingEventTooLarge(
                    maximum: resourceLimits.maximumStreamingEventBytes
                )
            }
            streamedBytes += lineBytes + 1
            guard streamedBytes <= resourceLimits.maximumStreamingResponseBytes else {
                throw AnthropicLanguageModelError.streamingResponseTooLarge(
                    maximum: resourceLimits.maximumStreamingResponseBytes
                )
            }
            streamedEvents += 1
            guard streamedEvents <= resourceLimits.maximumStreamingEvents else {
                throw AnthropicLanguageModelError.tooManyStreamingEvents(
                    maximum: resourceLimits.maximumStreamingEvents
                )
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8) else { continue }
            let event: AnthropicStreamEvent
            do {
                event = try JSONDecoder().decode(AnthropicStreamEvent.self, from: data)
            } catch {
                throw AnthropicLanguageModelError.invalidResponse(
                    "A streaming event did not match Anthropic Messages."
                )
            }
            if event.type == "message_start" {
                responseID = event.message?.id
                responseModel = event.message?.model
                inputTokens = event.message?.usage?.inputTokens
                outputTokens = event.message?.usage?.outputTokens
            } else if event.type == "content_block_delta",
                event.delta?.type == "text_delta", let delta = event.delta?.text,
                !delta.isEmpty
            {
                content += delta
                continuation.yield(.textDelta(delta))
            } else if event.type == "message_delta" {
                stopReason = event.delta?.stopReason ?? stopReason
                outputTokens = event.usage?.outputTokens ?? outputTokens
            }
        }
        guard !content.isEmpty else {
            throw AnthropicLanguageModelError.invalidResponse(
                "The stream ended without generated text."
            )
        }

        let usage = LanguageModelUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalTokens: Self.total(inputTokens, outputTokens)
        )
        var metadata = ["http.status": String(stream.statusCode)]
        if let responseID { metadata["response.id"] = responseID }
        if let responseModel { metadata["response.model"] = responseModel }
        if let stopReason { metadata["response.finish-reason"] = stopReason }
        if let requestID = Self.header(named: "request-id", in: stream.headers) {
            metadata["http.request-id"] = requestID
        }
        let response = LanguageModelResponse(
            content: content,
            provider: providerIdentifier,
            metadata: metadata,
            usage: usage,
            finishReason: stopReason.map(Self.finishReason)
        )
        await onEvent?(
            .requestSucceeded(
                provider: providerIdentifier,
                statusCode: stream.statusCode,
                attempt: 1
            )
        )
        continuation.yield(.completed(response))
        continuation.finish()
    }

    private func makeBody(
        for request: LanguageModelRequest,
        streaming: Bool = false
    ) throws -> AnthropicRequestBody {
        var temperature = request.options.temperature
        var topProbability: Double?
        if let temperature, !(0...1).contains(temperature) {
            throw AnthropicLanguageModelError.invalidGenerationOption("temperature")
        }
        let maximumTokens =
            request.options.maximumResponseTokens
            ?? defaultMaximumResponseTokens
        guard maximumTokens > 0 else {
            throw
                AnthropicLanguageModelError
                .invalidGenerationOption("maximumResponseTokens")
        }
        switch request.options.sampling {
        case nil: break
        case .greedy: temperature = 0
        case let .randomTopK(k, seed):
            throw AnthropicLanguageModelError.unsupportedSampling(
                .randomTopK(k, seed: seed)
            )
        case let .randomProbabilityThreshold(value, seed):
            guard (0...1).contains(value), seed == nil else {
                if seed != nil {
                    throw AnthropicLanguageModelError.unsupportedSampling(
                        .randomProbabilityThreshold(value, seed: seed)
                    )
                }
                throw
                    AnthropicLanguageModelError
                    .invalidGenerationOption("probabilityThreshold")
            }
            topProbability = value
        }

        let system = [defaultInstructions, request.instructions]
            .compactMap(Self.nonEmpty)
            .joined(separator: "\n\n")
        var messages = [
            AnthropicMessage(
                role: "user",
                content: try makeContent(prompt: request.prompt, input: request.input)
            )
        ]
        for message in request.messages {
            messages.append(try makeMessage(message))
        }

        let disablesTools = request.toolChoice == LanguageModelToolChoice.none
        let tools =
            request.tools.isEmpty || disablesTools
            ? nil
            : request.tools.map(AnthropicTool.init)
        let choice =
            tools == nil
            ? nil
            : AnthropicToolChoice(
                request.toolChoice ?? .automatic,
                parallelToolCalls: request.parallelToolCalls
            )
        return AnthropicRequestBody(
            model: modelIdentifier,
            maximumTokens: maximumTokens,
            system: system.isEmpty ? nil : system,
            messages: messages,
            temperature: temperature,
            topProbability: topProbability,
            tools: tools,
            toolChoice: choice,
            outputConfiguration: request.responseFormat.map(
                AnthropicOutputConfiguration.init
            ),
            stream: streaming ? true : nil
        )
    }

    private func makeMessage(
        _ message: LanguageModelMessage
    ) throws -> AnthropicMessage {
        switch message {
        case let .user(content):
            return AnthropicMessage(role: "user", content: .text(content))
        case let .userContent(parts):
            return AnthropicMessage(
                role: "user",
                content: .blocks(try parts.map(makeContentBlock))
            )
        case let .assistant(content, toolCalls):
            var blocks: [AnthropicContentBlock] = []
            if let content, !content.isEmpty { blocks.append(.text(content)) }
            for call in toolCalls {
                let input: JSONValue
                do {
                    input = try JSONDecoder().decode(
                        JSONValue.self,
                        from: Data(call.arguments.utf8)
                    )
                } catch {
                    throw
                        AnthropicLanguageModelError
                        .invalidToolArguments(tool: call.name)
                }
                blocks.append(.toolUse(id: call.id, name: call.name, input: input))
            }
            return AnthropicMessage(role: "assistant", content: .blocks(blocks))
        case let .tool(callID, content):
            return AnthropicMessage(
                role: "user",
                content: .blocks([.toolResult(toolUseID: callID, content: content)])
            )
        }
    }

    private func makeContent(
        prompt: String,
        input: [LanguageModelInputPart]
    ) throws -> AnthropicMessageContent {
        guard !input.isEmpty else { return .text(prompt) }
        return .blocks(
            try ([LanguageModelInputPart.text(prompt)] + input).map(makeContentBlock)
        )
    }

    private func makeContentBlock(
        _ part: LanguageModelInputPart
    ) throws -> AnthropicContentBlock {
        switch part {
        case let .text(text): return .text(text)
        case let .image(image):
            switch image.source {
            case let .url(url):
                guard let scheme = url.scheme?.lowercased(),
                    ["http", "https"].contains(scheme), url.host != nil
                else { throw AnthropicLanguageModelError.invalidImageURL }
                return .image(.url(url.absoluteString))
            case let .data(data, mediaType):
                guard mediaType.lowercased().hasPrefix("image/"),
                    !mediaType.contains(where: { $0.isWhitespace })
                else {
                    throw AnthropicLanguageModelError.invalidImageMediaType(mediaType)
                }
                guard data.count <= maximumInlineImageBytes else {
                    throw AnthropicLanguageModelError.inlineImageTooLarge(
                        byteCount: data.count,
                        maximum: maximumInlineImageBytes
                    )
                }
                return .image(
                    .base64(mediaType: mediaType, data: data.base64EncodedString())
                )
            }
        }
    }

    private func makeURLRequest(body: AnthropicRequestBody) async throws -> URLRequest {
        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: requestTimeoutSeconds
        )
        request.httpMethod = "POST"
        let data: Data
        do { data = try JSONEncoder().encode(body) } catch {
            throw AnthropicLanguageModelError.requestEncoding(
                WorkflowFailure(error: error)
            )
        }
        guard data.count <= resourceLimits.maximumRequestBodyBytes else {
            throw AnthropicLanguageModelError.requestBodyTooLarge(
                maximum: resourceLimits.maximumRequestBodyBytes
            )
        }
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        for (name, value) in try await headers.values() {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func decode(
        _ response: HTTPModelTransportResponse
    ) throws -> LanguageModelResponse {
        let body: AnthropicResponseBody
        do {
            body = try JSONDecoder().decode(AnthropicResponseBody.self, from: response.data)
        } catch {
            throw AnthropicLanguageModelError.invalidResponse(
                "The JSON body does not match Anthropic Messages."
            )
        }
        let content = body.content.filter { $0.type == "text" }
            .compactMap(\.text).joined()
        let toolCalls = try body.content.compactMap { block -> LanguageModelToolCall? in
            guard block.type == "tool_use" else { return nil }
            guard let id = block.id, let name = block.name, let input = block.input else {
                throw AnthropicLanguageModelError.invalidResponse(
                    "A tool-use block omitted its identifier, name, or input."
                )
            }
            let data = try JSONEncoder().encode(input)
            return LanguageModelToolCall(
                id: id,
                name: name,
                arguments: String(decoding: data, as: UTF8.self)
            )
        }
        guard !content.isEmpty || !toolCalls.isEmpty else {
            throw AnthropicLanguageModelError.invalidResponse(
                "The response contained neither text nor tool calls."
            )
        }
        let usage = body.usage.map {
            LanguageModelUsage(
                inputTokens: $0.inputTokens,
                outputTokens: $0.outputTokens,
                totalTokens: Self.total($0.inputTokens, $0.outputTokens)
            )
        }
        var metadata = ["http.status": String(response.statusCode)]
        if let id = body.id { metadata["response.id"] = id }
        if let model = body.model { metadata["response.model"] = model }
        if let reason = body.stopReason { metadata["response.finish-reason"] = reason }
        if let requestID = response.header(named: "request-id") {
            metadata["http.request-id"] = requestID
        }
        return LanguageModelResponse(
            content: content,
            provider: providerIdentifier,
            metadata: metadata,
            toolCalls: toolCalls,
            usage: usage,
            finishReason: body.stopReason.map(Self.finishReason)
        )
    }

    private func validate(_ response: HTTPModelTransportResponse) throws {
        guard response.data.count <= resourceLimits.maximumResponseBodyBytes else {
            throw AnthropicLanguageModelError.responseBodyTooLarge(
                maximum: resourceLimits.maximumResponseBodyBytes
            )
        }
    }

    private func makeHTTPError(
        _ response: HTTPModelTransportResponse,
        attempts: Int
    ) -> AnthropicLanguageModelError {
        let error = try? JSONDecoder().decode(
            AnthropicErrorEnvelope.self,
            from: response.data
        ).error
        let retryable = retryPolicy.retryableStatusCodes.contains(response.statusCode)
        return .httpStatus(
            statusCode: response.statusCode,
            type: error?.type,
            message: includesProviderErrorMessages ? error?.message : nil,
            retryable: retryable,
            attempts: attempts
        )
    }

    private func retryDelay(
        _ response: HTTPModelTransportResponse,
        failedAttempt: Int
    ) -> Double {
        if let value = response.header(named: "Retry-After"),
            let seconds = Double(value), seconds >= 0
        {
            return min(retryPolicy.maximumDelaySeconds, seconds)
        }
        return exponentialDelay(after: failedAttempt)
    }

    private func exponentialDelay(after attempt: Int) -> Double {
        min(
            retryPolicy.maximumDelaySeconds,
            retryPolicy.baseDelaySeconds * pow(2, Double(max(0, attempt - 1)))
        )
    }

    private static func finishReason(_ reason: String) -> LanguageModelFinishReason {
        switch reason {
        case "end_turn", "stop_sequence": .stop
        case "max_tokens": .length
        case "tool_use": .toolCalls
        case "refusal": .contentFilter
        default: LanguageModelFinishReason(rawValue: reason)
        }
    }

    private static func total(_ input: Int?, _ output: Int?) -> Int? {
        guard input != nil || output != nil else { return nil }
        return (input ?? 0) + (output ?? 0)
    }

    private static func isRetryableTransportError(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [
            .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
            .networkConnectionLost, .notConnectedToInternet, .internationalRoamingOff,
            .callIsActive, .dataNotAllowed,
        ].contains(error.code)
    }

    private static func header(
        named name: String,
        in headers: [String: String]
    ) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = trimmed(value)
        return result.isEmpty ? nil : result
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isValid(_ limits: HTTPModelResourceLimits) -> Bool {
        limits.maximumRequestBodyBytes > 0
            && limits.maximumResponseBodyBytes > 0
            && limits.maximumStreamingEventBytes > 0
            && limits.maximumStreamingResponseBytes >= limits.maximumStreamingEventBytes
            && limits.maximumStreamingEvents > 0
    }

    private static func isStructurallyValid(_ endpoint: URL) -> Bool {
        guard let scheme = endpoint.scheme?.lowercased(),
            ["http", "https"].contains(scheme), endpoint.host != nil,
            endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil
        else { return false }
        return true
    }

    private static func isAllowed(
        _ endpoint: URL,
        under policy: HTTPModelEndpointSecurityPolicy
    ) -> Bool {
        if endpoint.scheme?.lowercased() == "https" { return true }
        guard policy == .allowInsecureLoopback,
            let host = endpoint.host?.lowercased()
        else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }
}

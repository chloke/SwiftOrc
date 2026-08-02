import Foundation
import SwiftOrc
import SwiftOrcHTTP

/// Configuration errors rejected before a Responses request can be sent.
public enum ResponsesCompatibleConfigurationError: Error, Sendable, Equatable {
    case emptyProviderIdentifier
    case emptyModelIdentifier
    case invalidEndpoint
    case insecureEndpoint
    case invalidRequestTimeout
    case invalidRetryPolicy
    case invalidMaximumInlineImageBytes
    case invalidResourceLimits
}

/// Failures returned by a Responses-compatible provider.
public enum ResponsesCompatibleLanguageModelError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case unsupportedSampling(LanguageModelSampling)
    case invalidGenerationOption(String)
    case invalidImageMediaType(String)
    case invalidImageURL
    case inlineImageTooLarge(byteCount: Int, maximum: Int)
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
        code: String?,
        type: String?,
        message: String?,
        retryable: Bool,
        attempts: Int
    )
    case invalidResponse(String)

    public var isRetryable: Bool {
        switch self {
        case let .httpStatus(_, _, _, _, retryable, _): retryable
        case let .transport(_, retryable, _): retryable
        default: false
        }
    }

    public var description: String {
        switch self {
        case .unsupportedSampling:
            "The requested sampling mode is not supported by Responses."
        case let .invalidGenerationOption(option):
            "The generation option '\(option)' is invalid."
        case let .invalidImageMediaType(mediaType):
            "The image media type '\(mediaType)' is invalid."
        case .invalidImageURL:
            "The image URL must be an absolute HTTP or HTTPS URL."
        case let .inlineImageTooLarge(byteCount, maximum):
            "The inline image contains \(byteCount) bytes; the configured maximum is \(maximum)."
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
        case let .httpStatus(statusCode, _, _, message, _, attempts):
            "The provider returned HTTP \(statusCode) after \(attempts) attempt(s)\(message.map { ": \($0)" } ?? "")"
        case let .invalidResponse(reason):
            "The provider returned an invalid response: \(reason)"
        }
    }
}

/// A stateless adapter for OpenAI's Responses API and compatible endpoints.
///
/// Each request explicitly sends `store: false`. Conversation history is
/// represented by ``LanguageModelRequest/messages`` rather than provider-side
/// response IDs, which keeps routing and fallback deterministic.
public struct ResponsesCompatibleLanguageModel: StreamingWorkflowLanguageModel {
    public static let openAIEndpoint = URL(
        string: "https://api.openai.com/v1/responses"
    )!

    public let providerIdentifier: String
    public let endpoint: URL
    public let modelIdentifier: String
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
        providerIdentifier: String,
        endpoint: URL,
        modelIdentifier: String,
        headers: HTTPRequestHeaders = .none,
        additionalHeaders: [String: String] = [:],
        defaultInstructions: String? = nil,
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
            throw ResponsesCompatibleConfigurationError.emptyProviderIdentifier
        }
        guard !Self.trimmed(modelIdentifier).isEmpty else {
            throw ResponsesCompatibleConfigurationError.emptyModelIdentifier
        }
        guard Self.isStructurallyValid(endpoint) else {
            throw ResponsesCompatibleConfigurationError.invalidEndpoint
        }
        guard Self.isAllowed(endpoint, under: endpointSecurityPolicy) else {
            throw ResponsesCompatibleConfigurationError.insecureEndpoint
        }
        guard requestTimeoutSeconds > 0 else {
            throw ResponsesCompatibleConfigurationError.invalidRequestTimeout
        }
        guard maximumInlineImageBytes > 0 else {
            throw ResponsesCompatibleConfigurationError.invalidMaximumInlineImageBytes
        }
        guard Self.isValid(resourceLimits) else {
            throw ResponsesCompatibleConfigurationError.invalidResourceLimits
        }
        guard retryPolicy.maximumAttempts >= 1,
            retryPolicy.baseDelaySeconds >= 0,
            retryPolicy.maximumDelaySeconds >= retryPolicy.baseDelaySeconds
        else {
            throw ResponsesCompatibleConfigurationError.invalidRetryPolicy
        }

        self.providerIdentifier = providerIdentifier
        self.endpoint = endpoint
        self.modelIdentifier = modelIdentifier
        self.headers = headers
        self.additionalHeaders = additionalHeaders
        self.defaultInstructions = defaultInstructions
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
            } catch let error as ResponsesCompatibleLanguageModelError {
                throw error
            } catch {
                throw ResponsesCompatibleLanguageModelError.requestEncoding(
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
            } catch let error as ResponsesCompatibleLanguageModelError {
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
                    throw ResponsesCompatibleLanguageModelError.transport(
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
                ResponsesCompatibleLanguageModelError
                .unsupportedStreamingFeature("tool-calling")
        }
        guard let transport = transport as? any HTTPStreamingModelTransport else {
            throw ResponsesCompatibleLanguageModelError.streamingTransportUnavailable
        }

        let body = try makeBody(for: request, streaming: true)
        let urlRequest = try await makeURLRequest(body: body)
        await onEvent?(.requestStarted(provider: providerIdentifier, attempt: 1))
        let stream = try await transport.stream(urlRequest)
        guard (200...299).contains(stream.statusCode) else {
            throw ResponsesCompatibleLanguageModelError.httpStatus(
                statusCode: stream.statusCode,
                code: nil,
                type: nil,
                message: nil,
                retryable: retryPolicy.retryableStatusCodes.contains(stream.statusCode),
                attempts: 1
            )
        }

        var completion: LanguageModelResponse?
        var streamedBytes = 0
        var streamedEvents = 0
        for try await line in stream.lines {
            try Task.checkCancellation()
            let lineBytes = line.utf8.count
            guard lineBytes <= resourceLimits.maximumStreamingEventBytes else {
                throw ResponsesCompatibleLanguageModelError.streamingEventTooLarge(
                    maximum: resourceLimits.maximumStreamingEventBytes
                )
            }
            streamedBytes += lineBytes + 1
            guard streamedBytes <= resourceLimits.maximumStreamingResponseBytes else {
                throw ResponsesCompatibleLanguageModelError.streamingResponseTooLarge(
                    maximum: resourceLimits.maximumStreamingResponseBytes
                )
            }
            streamedEvents += 1
            guard streamedEvents <= resourceLimits.maximumStreamingEvents else {
                throw ResponsesCompatibleLanguageModelError.tooManyStreamingEvents(
                    maximum: resourceLimits.maximumStreamingEvents
                )
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let data = payload.data(using: .utf8) else {
                continue
            }
            let event: ResponsesStreamEvent
            do {
                event = try JSONDecoder().decode(ResponsesStreamEvent.self, from: data)
            } catch {
                throw ResponsesCompatibleLanguageModelError.invalidResponse(
                    "A streaming event did not match Responses."
                )
            }
            if event.type == "response.output_text.delta", let delta = event.delta,
                !delta.isEmpty
            {
                continuation.yield(.textDelta(delta))
            } else if ["response.completed", "response.incomplete"].contains(event.type),
                let body = event.response
            {
                completion = try makeResponse(
                    body, statusCode: stream.statusCode, headers: stream.headers)
            } else if event.type == "response.failed" {
                throw ResponsesCompatibleLanguageModelError.invalidResponse(
                    "The streamed response failed."
                )
            }
        }

        guard let completion else {
            throw ResponsesCompatibleLanguageModelError.invalidResponse(
                "The stream ended without a completed response."
            )
        }
        await onEvent?(
            .requestSucceeded(
                provider: providerIdentifier,
                statusCode: stream.statusCode,
                attempt: 1
            )
        )
        continuation.yield(.completed(completion))
        continuation.finish()
    }

    private func makeBody(
        for request: LanguageModelRequest,
        streaming: Bool = false
    ) throws -> ResponsesRequestBody {
        var temperature = request.options.temperature
        var topProbability: Double?
        if let temperature, !(0...2).contains(temperature) {
            throw
                ResponsesCompatibleLanguageModelError
                .invalidGenerationOption("temperature")
        }
        if let maximum = request.options.maximumResponseTokens, maximum <= 0 {
            throw
                ResponsesCompatibleLanguageModelError
                .invalidGenerationOption("maximumResponseTokens")
        }
        switch request.options.sampling {
        case nil: break
        case .greedy: temperature = 0
        case let .randomTopK(k, seed):
            throw ResponsesCompatibleLanguageModelError.unsupportedSampling(
                .randomTopK(k, seed: seed)
            )
        case let .randomProbabilityThreshold(value, seed):
            guard (0...1).contains(value), seed == nil else {
                if seed != nil {
                    throw ResponsesCompatibleLanguageModelError.unsupportedSampling(
                        .randomProbabilityThreshold(value, seed: seed)
                    )
                }
                throw
                    ResponsesCompatibleLanguageModelError
                    .invalidGenerationOption("probabilityThreshold")
            }
            topProbability = value
        }

        let instructions = [defaultInstructions, request.instructions]
            .compactMap(Self.nonEmpty)
            .joined(separator: "\n\n")
        var input = [
            ResponsesInputItem.message(
                role: "user",
                content: try makeContent(prompt: request.prompt, input: request.input)
            )
        ]
        for message in request.messages {
            input.append(contentsOf: try makeItems(message))
        }

        return ResponsesRequestBody(
            model: modelIdentifier,
            instructions: instructions.isEmpty ? nil : instructions,
            input: input,
            temperature: temperature,
            topProbability: topProbability,
            maximumOutputTokens: request.options.maximumResponseTokens,
            tools: request.tools.isEmpty ? nil : request.tools.map(ResponsesTool.init),
            toolChoice: request.toolChoice.map(ResponsesToolChoice.init),
            parallelToolCalls: request.parallelToolCalls,
            text: request.responseFormat.map(ResponsesTextConfiguration.init),
            stream: streaming ? true : nil
        )
    }

    private func makeItems(
        _ message: LanguageModelMessage
    ) throws -> [ResponsesInputItem] {
        switch message {
        case let .user(content):
            return [.message(role: "user", content: .text(content))]
        case let .userContent(parts):
            return [
                .message(
                    role: "user",
                    content: .parts(try parts.map(makeContentPart))
                )
            ]
        case let .assistant(content, toolCalls):
            var items: [ResponsesInputItem] = []
            if let content, !content.isEmpty {
                items.append(.message(role: "assistant", content: .text(content)))
            }
            items.append(
                contentsOf: toolCalls.map {
                    .functionCall(callID: $0.id, name: $0.name, arguments: $0.arguments)
                }
            )
            return items
        case let .tool(callID, content):
            return [.functionCallOutput(callID: callID, output: content)]
        }
    }

    private func makeContent(
        prompt: String,
        input: [LanguageModelInputPart]
    ) throws -> ResponsesMessageContent {
        guard !input.isEmpty else { return .text(prompt) }
        return .parts(
            try ([LanguageModelInputPart.text(prompt)] + input).map(makeContentPart)
        )
    }

    private func makeContentPart(
        _ part: LanguageModelInputPart
    ) throws -> ResponsesInputContentPart {
        switch part {
        case let .text(text): return .text(text)
        case let .image(image):
            let url: String
            switch image.source {
            case let .url(value):
                guard let scheme = value.scheme?.lowercased(),
                    ["http", "https"].contains(scheme), value.host != nil
                else { throw ResponsesCompatibleLanguageModelError.invalidImageURL }
                url = value.absoluteString
            case let .data(data, mediaType):
                guard mediaType.lowercased().hasPrefix("image/"),
                    !mediaType.contains(where: { $0.isWhitespace })
                else {
                    throw
                        ResponsesCompatibleLanguageModelError
                        .invalidImageMediaType(mediaType)
                }
                guard data.count <= maximumInlineImageBytes else {
                    throw ResponsesCompatibleLanguageModelError.inlineImageTooLarge(
                        byteCount: data.count,
                        maximum: maximumInlineImageBytes
                    )
                }
                url = "data:\(mediaType);base64,\(data.base64EncodedString())"
            }
            return .image(
                url: url,
                detail: image.detail == .automatic ? "auto" : image.detail.rawValue
            )
        }
    }

    private func makeURLRequest(body: ResponsesRequestBody) async throws -> URLRequest {
        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: requestTimeoutSeconds
        )
        request.httpMethod = "POST"
        let data: Data
        do { data = try JSONEncoder().encode(body) } catch {
            throw ResponsesCompatibleLanguageModelError.requestEncoding(
                WorkflowFailure(error: error)
            )
        }
        guard data.count <= resourceLimits.maximumRequestBodyBytes else {
            throw ResponsesCompatibleLanguageModelError.requestBodyTooLarge(
                maximum: resourceLimits.maximumRequestBodyBytes
            )
        }
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        for (name, value) in try await headers.values() {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func decode(
        _ response: HTTPModelTransportResponse
    ) throws -> LanguageModelResponse {
        let body: ResponsesResponseBody
        do {
            body = try JSONDecoder().decode(ResponsesResponseBody.self, from: response.data)
        } catch {
            throw ResponsesCompatibleLanguageModelError.invalidResponse(
                "The JSON body does not match Responses."
            )
        }
        return try makeResponse(body, statusCode: response.statusCode, headers: response.headers)
    }

    private func makeResponse(
        _ body: ResponsesResponseBody,
        statusCode: Int,
        headers: [String: String]
    ) throws -> LanguageModelResponse {
        let contentBlocks = body.output.flatMap { $0.content ?? [] }
        let content = contentBlocks.compactMap { block in
            switch block.type {
            case "output_text": block.text
            case "refusal": block.refusal
            default: nil
            }
        }.joined()
        let refused = contentBlocks.contains { $0.type == "refusal" }
        let toolCalls = try body.output.compactMap { item -> LanguageModelToolCall? in
            guard item.type == "function_call" else { return nil }
            guard let id = item.callID, let name = item.name, let arguments = item.arguments else {
                throw ResponsesCompatibleLanguageModelError.invalidResponse(
                    "A function call omitted its identifier, name, or arguments."
                )
            }
            return LanguageModelToolCall(id: id, name: name, arguments: arguments)
        }
        guard !content.isEmpty || !toolCalls.isEmpty else {
            throw ResponsesCompatibleLanguageModelError.invalidResponse(
                "The response contained neither output text nor function calls."
            )
        }

        let finishReason: LanguageModelFinishReason?
        if refused {
            finishReason = .contentFilter
        } else if !toolCalls.isEmpty {
            finishReason = .toolCalls
        } else if body.status == "incomplete",
            body.incompleteDetails?.reason == "max_output_tokens"
        {
            finishReason = .length
        } else {
            finishReason = body.status.map {
                $0 == "completed" ? .stop : LanguageModelFinishReason(rawValue: $0)
            }
        }
        let usage = body.usage.map {
            LanguageModelUsage(
                inputTokens: $0.inputTokens,
                outputTokens: $0.outputTokens,
                totalTokens: $0.totalTokens
            )
        }
        var metadata = ["http.status": String(statusCode)]
        if let id = body.id { metadata["response.id"] = id }
        if let model = body.model { metadata["response.model"] = model }
        if let status = body.status { metadata["response.status"] = status }
        if let requestID = Self.header(named: "x-request-id", in: headers) {
            metadata["http.request-id"] = requestID
        }
        return LanguageModelResponse(
            content: content,
            provider: providerIdentifier,
            metadata: metadata,
            toolCalls: toolCalls,
            usage: usage,
            finishReason: finishReason
        )
    }

    private func validate(_ response: HTTPModelTransportResponse) throws {
        guard response.data.count <= resourceLimits.maximumResponseBodyBytes else {
            throw ResponsesCompatibleLanguageModelError.responseBodyTooLarge(
                maximum: resourceLimits.maximumResponseBodyBytes
            )
        }
    }

    private func makeHTTPError(
        _ response: HTTPModelTransportResponse,
        attempts: Int
    ) -> ResponsesCompatibleLanguageModelError {
        let error = try? JSONDecoder().decode(
            ResponsesErrorEnvelope.self,
            from: response.data
        ).error
        let retryable =
            retryPolicy.retryableStatusCodes.contains(response.statusCode)
            && error?.code != "insufficient_quota"
        return .httpStatus(
            statusCode: response.statusCode,
            code: error?.code,
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

import Foundation
import SwiftOrc

/// Which Chat Completions role carries request-level instructions.
public enum OpenAICompatibleInstructionRole: String, Sendable, Equatable,
    Codable
{
    case developer
    case system
}

/// Which endpoint schemes the adapter accepts. Secure HTTPS is the default;
/// cleartext HTTP can be enabled only for a loopback development server.
public enum HTTPModelEndpointSecurityPolicy: Sendable, Equatable {
    case httpsOnly
    case allowInsecureLoopback
}

/// Retry settings used inside one remote provider before the router moves on.
public struct HTTPModelRetryPolicy: Sendable, Equatable {
    public var maximumAttempts: Int
    public var baseDelaySeconds: Double
    public var maximumDelaySeconds: Double
    public var retryableStatusCodes: Set<Int>

    public init(
        maximumAttempts: Int = 2,
        baseDelaySeconds: Double = 0.5,
        maximumDelaySeconds: Double = 8,
        retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]
    ) {
        self.maximumAttempts = maximumAttempts
        self.baseDelaySeconds = baseDelaySeconds
        self.maximumDelaySeconds = maximumDelaySeconds
        self.retryableStatusCodes = retryableStatusCodes
    }

    public static let none = HTTPModelRetryPolicy(
        maximumAttempts: 1,
        baseDelaySeconds: 0,
        maximumDelaySeconds: 0,
        retryableStatusCodes: []
    )

    func delaySeconds(afterFailedAttempt attempt: Int) -> Double {
        let multiplier = pow(2, Double(max(0, attempt - 1)))
        return min(maximumDelaySeconds, baseDelaySeconds * multiplier)
    }
}

/// Configuration errors rejected before the adapter can make a request.
public enum OpenAICompatibleConfigurationError: Error, Sendable, Equatable {
    case emptyProviderIdentifier
    case emptyModelIdentifier
    case invalidEndpoint
    case invalidRequestTimeout
    case invalidRetryPolicy
    case invalidMaximumInlineImageBytes
    case invalidResourceLimits
    case insecureEndpoint
}

/// Failures returned by an OpenAI-compatible Chat Completions provider.
public enum OpenAICompatibleLanguageModelError: Error, Sendable, Equatable,
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
    case transport(
        failure: WorkflowFailure,
        retryable: Bool,
        attempts: Int
    )
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
        case let .httpStatus(_, _, _, _, retryable, _):
            return retryable
        case let .transport(_, retryable, _):
            return retryable
        case .unsupportedSampling, .invalidGenerationOption,
            .invalidImageMediaType, .invalidImageURL, .inlineImageTooLarge,
            .requestBodyTooLarge, .responseBodyTooLarge,
            .streamingEventTooLarge, .streamingResponseTooLarge,
            .tooManyStreamingEvents,
            .streamingTransportUnavailable, .unsupportedStreamingFeature,
            .requestEncoding, .invalidResponse:
            return false
        }
    }

    public var description: String {
        switch self {
        case .unsupportedSampling:
            return "The requested sampling mode is not supported by Chat Completions."
        case let .invalidGenerationOption(option):
            return "The generation option '\(option)' is invalid."
        case let .invalidImageMediaType(mediaType):
            return "The image media type '\(mediaType)' is invalid."
        case .invalidImageURL:
            return "The image URL must be an absolute HTTP or HTTPS URL."
        case let .inlineImageTooLarge(byteCount, maximum):
            return
                "The inline image contains \(byteCount) bytes; the configured maximum is \(maximum)."
        case let .requestBodyTooLarge(maximum):
            return "The encoded request exceeds the configured \(maximum)-byte limit."
        case let .responseBodyTooLarge(maximum):
            return "The provider response exceeds the configured \(maximum)-byte limit."
        case let .streamingEventTooLarge(maximum):
            return "A streaming event exceeds the configured \(maximum)-byte limit."
        case let .streamingResponseTooLarge(maximum):
            return "The streaming response exceeds the configured \(maximum)-byte limit."
        case let .tooManyStreamingEvents(maximum):
            return "The streaming response exceeds the configured \(maximum)-event limit."
        case .streamingTransportUnavailable:
            return "The configured HTTP transport does not support streaming."
        case let .unsupportedStreamingFeature(feature):
            return "Streaming does not support the requested feature '\(feature)'."
        case let .requestEncoding(failure):
            return "The model request could not be encoded: \(failure.message)"
        case let .transport(failure, _, attempts):
            return "The HTTP transport failed after \(attempts) attempt(s): \(failure.message)"
        case let .httpStatus(statusCode, _, _, message, _, attempts):
            let detail = message.map { ": \($0)" } ?? ""
            return "The provider returned HTTP \(statusCode) after \(attempts) attempt(s)\(detail)"
        case let .invalidResponse(reason):
            return "The provider returned an invalid response: \(reason)"
        }
    }
}

/// A redacted diagnostic event. Prompt text, bodies, headers, endpoints, and
/// credentials are intentionally excluded.
public enum HTTPModelProviderEvent: Sendable, Equatable {
    case requestStarted(provider: String, attempt: Int)
    case retryScheduled(
        provider: String,
        nextAttempt: Int,
        delaySeconds: Double,
        reason: RetryReason
    )
    case requestSucceeded(provider: String, statusCode: Int, attempt: Int)
    case requestFailed(
        provider: String,
        statusCode: Int?,
        attempt: Int,
        retryable: Bool
    )

    public enum RetryReason: Sendable, Equatable {
        case transport
        case statusCode(Int)
    }
}

public typealias HTTPModelProviderEventHandler =
    @Sendable (
        HTTPModelProviderEvent
    ) async -> Void

/// A text and image-input adapter for OpenAI-compatible Chat Completions
/// endpoints.
///
/// The endpoint is explicit so the same adapter can target OpenAI, a developer's
/// own gateway, or a compatible self-hosted server. It never logs request data.
public struct OpenAICompatibleLanguageModel: StreamingWorkflowLanguageModel {
    public static let openAIEndpoint: URL = {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.openai.com"
        components.path = "/v1/chat/completions"
        return components.url ?? URL(fileURLWithPath: "/v1/chat/completions")
    }()

    public let providerIdentifier: String
    public let endpoint: URL
    public let modelIdentifier: String
    public let instructionRole: OpenAICompatibleInstructionRole
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
        instructionRole: OpenAICompatibleInstructionRole = .developer,
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
        guard
            !providerIdentifier.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        else {
            throw OpenAICompatibleConfigurationError.emptyProviderIdentifier
        }
        guard
            !modelIdentifier.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        else {
            throw OpenAICompatibleConfigurationError.emptyModelIdentifier
        }
        guard Self.isStructurallyValid(endpoint) else {
            throw OpenAICompatibleConfigurationError.invalidEndpoint
        }
        guard Self.isAllowed(endpoint, under: endpointSecurityPolicy) else {
            throw OpenAICompatibleConfigurationError.insecureEndpoint
        }
        guard requestTimeoutSeconds > 0 else {
            throw OpenAICompatibleConfigurationError.invalidRequestTimeout
        }
        guard maximumInlineImageBytes > 0 else {
            throw OpenAICompatibleConfigurationError
                .invalidMaximumInlineImageBytes
        }
        guard resourceLimits.isValid else {
            throw OpenAICompatibleConfigurationError.invalidResourceLimits
        }
        guard retryPolicy.maximumAttempts >= 1,
            retryPolicy.baseDelaySeconds >= 0,
            retryPolicy.maximumDelaySeconds >= retryPolicy.baseDelaySeconds
        else {
            throw OpenAICompatibleConfigurationError.invalidRetryPolicy
        }

        self.providerIdentifier = providerIdentifier
        self.endpoint = endpoint
        self.modelIdentifier = modelIdentifier
        self.headers = headers
        self.additionalHeaders = additionalHeaders
        self.defaultInstructions = defaultInstructions
        self.instructionRole = instructionRole
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.maximumInlineImageBytes = maximumInlineImageBytes
        self.endpointSecurityPolicy = endpointSecurityPolicy
        self.resourceLimits = resourceLimits
        self.includesProviderErrorMessages = includesProviderErrorMessages
        self.retryPolicy = retryPolicy
        self.transport =
            transport
            ?? URLSessionHTTPModelTransport(limits: resourceLimits)
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
            await onEvent?(
                .requestStarted(
                    provider: providerIdentifier,
                    attempt: attempt
                )
            )

            let urlRequest: URLRequest
            do {
                urlRequest = try await makeURLRequest(body: body)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as OpenAICompatibleLanguageModelError {
                throw error
            } catch {
                throw OpenAICompatibleLanguageModelError.requestEncoding(
                    WorkflowFailure(error: error)
                )
            }

            do {
                let response = try await transport.send(urlRequest)
                try Task.checkCancellation()
                try validate(response)

                if (200...299).contains(response.statusCode) {
                    let result = try decodeSuccess(response)
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
                guard error.isRetryable,
                    attempt < retryPolicy.maximumAttempts
                else {
                    throw error
                }

                let delay = retryDelay(
                    response: response,
                    failedAttempt: attempt
                )
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
            } catch let error as OpenAICompatibleLanguageModelError {
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
                    throw OpenAICompatibleLanguageModelError.transport(
                        failure: WorkflowFailure(error: error),
                        retryable: retryable,
                        attempts: attempt
                    )
                }

                let delay = retryPolicy.delaySeconds(
                    afterFailedAttempt: attempt
                )
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
                    try await stream(request, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func stream(
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
                OpenAICompatibleLanguageModelError
                .unsupportedStreamingFeature("tool-calling")
        }
        guard let streamingTransport = transport as? any HTTPStreamingModelTransport else {
            throw OpenAICompatibleLanguageModelError.streamingTransportUnavailable
        }

        let body = try makeBody(for: request, streaming: true)
        let urlRequest = try await makeURLRequest(body: body)
        await onEvent?(
            .requestStarted(provider: providerIdentifier, attempt: 1)
        )
        let response = try await streamingTransport.stream(urlRequest)
        guard (200...299).contains(response.statusCode) else {
            await onEvent?(
                .requestFailed(
                    provider: providerIdentifier,
                    statusCode: response.statusCode,
                    attempt: 1,
                    retryable: retryPolicy.retryableStatusCodes.contains(
                        response.statusCode
                    )
                )
            )
            throw OpenAICompatibleLanguageModelError.httpStatus(
                statusCode: response.statusCode,
                code: nil,
                type: nil,
                message: nil,
                retryable: retryPolicy.retryableStatusCodes.contains(response.statusCode),
                attempts: 1
            )
        }

        let result = try await decodeStream(response, continuation: continuation)
        await onEvent?(
            .requestSucceeded(
                provider: providerIdentifier,
                statusCode: response.statusCode,
                attempt: 1
            )
        )
        continuation.yield(.completed(result))
        continuation.finish()
    }

    private func makeBody(
        for request: LanguageModelRequest,
        streaming: Bool = false
    ) throws -> ChatCompletionRequestBody {
        var messages: [ChatMessage] = []
        let instructions = [defaultInstructions, request.instructions]
            .compactMap(Self.nonEmpty)
            .joined(separator: "\n\n")
        if !instructions.isEmpty {
            messages.append(
                ChatMessage(
                    role: instructionRole.rawValue,
                    content: instructions
                )
            )
        }
        messages.append(
            try ChatMessage(
                userPrompt: request.prompt,
                input: request.input,
                maximumInlineImageBytes: maximumInlineImageBytes
            )
        )
        messages.append(
            contentsOf: try request.messages.map {
                try ChatMessage(
                    $0,
                    maximumInlineImageBytes: maximumInlineImageBytes
                )
            }
        )

        var temperature = request.options.temperature
        var topProbability: Double?
        var seed: UInt64?

        if let temperature, !(0...2).contains(temperature) {
            throw
                OpenAICompatibleLanguageModelError
                .invalidGenerationOption("temperature")
        }
        if let maximumTokens = request.options.maximumResponseTokens,
            maximumTokens <= 0
        {
            throw
                OpenAICompatibleLanguageModelError
                .invalidGenerationOption("maximumResponseTokens")
        }

        switch request.options.sampling {
        case nil:
            break
        case .greedy:
            temperature = 0
        case let .randomTopK(k, seed):
            throw OpenAICompatibleLanguageModelError.unsupportedSampling(
                .randomTopK(k, seed: seed)
            )
        case let .randomProbabilityThreshold(threshold, requestedSeed):
            guard (0...1).contains(threshold) else {
                throw
                    OpenAICompatibleLanguageModelError
                    .invalidGenerationOption("probabilityThreshold")
            }
            topProbability = threshold
            seed = requestedSeed
        }

        return ChatCompletionRequestBody(
            model: modelIdentifier,
            messages: messages,
            temperature: temperature,
            topProbability: topProbability,
            seed: seed,
            maximumCompletionTokens: request.options.maximumResponseTokens,
            tools: request.tools.isEmpty
                ? nil
                : request.tools.map(ChatTool.init),
            toolChoice: request.toolChoice.map(ChatToolChoice.init),
            parallelToolCalls: request.parallelToolCalls,
            responseFormat: request.responseFormat.map(ChatResponseFormat.init),
            stream: streaming ? true : nil,
            streamOptions: streaming ? ChatStreamOptions() : nil
        )
    }

    private func makeURLRequest(
        body: ChatCompletionRequestBody
    ) async throws -> URLRequest {
        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: requestTimeoutSeconds
        )
        request.httpMethod = "POST"
        let encodedBody = try JSONEncoder().encode(body)
        guard encodedBody.count <= resourceLimits.maximumRequestBodyBytes else {
            throw OpenAICompatibleLanguageModelError.requestBodyTooLarge(
                maximum: resourceLimits.maximumRequestBodyBytes
            )
        }
        request.httpBody = encodedBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        for (name, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        for (name, value) in try await headers.values() {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func decodeStream(
        _ response: HTTPModelTransportStream,
        continuation: AsyncThrowingStream<
            LanguageModelStreamEvent,
            any Error
        >.Continuation
    ) async throws -> LanguageModelResponse {
        var content = ""
        var streamedBytes = 0
        var streamedEvents = 0
        var responseID: String?
        var responseModel: String?
        var finishReason: LanguageModelFinishReason?
        var usage: LanguageModelUsage?

        for try await line in response.lines {
            try Task.checkCancellation()
            let lineBytes = line.utf8.count
            guard lineBytes <= resourceLimits.maximumStreamingEventBytes else {
                throw OpenAICompatibleLanguageModelError.streamingEventTooLarge(
                    maximum: resourceLimits.maximumStreamingEventBytes
                )
            }
            streamedBytes += lineBytes + 1
            guard
                streamedBytes <= resourceLimits.maximumStreamingResponseBytes
            else {
                throw
                    OpenAICompatibleLanguageModelError
                    .streamingResponseTooLarge(
                        maximum: resourceLimits.maximumStreamingResponseBytes
                    )
            }
            streamedEvents += 1
            guard streamedEvents <= resourceLimits.maximumStreamingEvents else {
                throw OpenAICompatibleLanguageModelError.tooManyStreamingEvents(
                    maximum: resourceLimits.maximumStreamingEvents
                )
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(
                in: .whitespaces
            )
            guard payload != "[DONE]" else { break }
            guard let data = payload.data(using: .utf8) else { continue }

            let chunk: ChatCompletionStreamChunk
            do {
                chunk = try JSONDecoder().decode(
                    ChatCompletionStreamChunk.self,
                    from: data
                )
            } catch {
                throw OpenAICompatibleLanguageModelError.invalidResponse(
                    "A streaming event did not match Chat Completions."
                )
            }

            responseID = chunk.id ?? responseID
            responseModel = chunk.model ?? responseModel
            if let delta = chunk.choices.first?.delta.content,
                !delta.isEmpty
            {
                content += delta
                continuation.yield(.textDelta(delta))
            }
            if let reason = chunk.choices.first?.finishReason {
                finishReason = LanguageModelFinishReason(rawValue: reason)
            }
            if let chunkUsage = chunk.usage {
                usage = LanguageModelUsage(
                    inputTokens: chunkUsage.promptTokens,
                    outputTokens: chunkUsage.completionTokens,
                    totalTokens: chunkUsage.totalTokens
                )
            }
        }

        var metadata = ["http.status": String(response.statusCode)]
        if let responseID { metadata["response.id"] = responseID }
        if let responseModel { metadata["response.model"] = responseModel }
        if let finishReason {
            metadata["response.finish-reason"] = finishReason.rawValue
        }
        if let inputTokens = usage?.inputTokens {
            metadata["usage.input-tokens"] = String(inputTokens)
        }
        if let outputTokens = usage?.outputTokens {
            metadata["usage.output-tokens"] = String(outputTokens)
        }
        if let totalTokens = usage?.totalTokens {
            metadata["usage.total-tokens"] = String(totalTokens)
        }
        if let requestID = response.header(named: "x-request-id") {
            metadata["http.request-id"] = requestID
        }

        return LanguageModelResponse(
            content: content,
            provider: providerIdentifier,
            metadata: metadata,
            usage: usage,
            finishReason: finishReason
        )
    }

    private func decodeSuccess(
        _ response: HTTPModelTransportResponse
    ) throws -> LanguageModelResponse {
        try validate(response)
        let body: ChatCompletionResponseBody
        do {
            body = try JSONDecoder().decode(
                ChatCompletionResponseBody.self,
                from: response.data
            )
        } catch {
            throw OpenAICompatibleLanguageModelError.invalidResponse(
                "The JSON body does not match Chat Completions."
            )
        }

        guard let choice = body.choices.first else {
            throw OpenAICompatibleLanguageModelError.invalidResponse(
                "No choice was returned."
            )
        }
        let toolCalls: [LanguageModelToolCall] =
            try choice.message.toolCalls?
            .map { call in
                guard call.type == "function" else {
                    throw OpenAICompatibleLanguageModelError.invalidResponse(
                        "An unsupported tool-call type was returned."
                    )
                }
                return LanguageModelToolCall(
                    id: call.id,
                    name: call.function.name,
                    arguments: call.function.arguments
                )
            } ?? []
        guard choice.message.content != nil || !toolCalls.isEmpty else {
            throw OpenAICompatibleLanguageModelError.invalidResponse(
                "The choice contained neither text nor tool calls."
            )
        }

        var metadata: [String: String] = [
            "http.status": String(response.statusCode)
        ]
        if let id = body.id { metadata["response.id"] = id }
        if let model = body.model { metadata["response.model"] = model }
        if let reason = choice.finishReason {
            metadata["response.finish-reason"] = reason
        }
        if let usage = body.usage {
            if let value = usage.promptTokens {
                metadata["usage.input-tokens"] = String(value)
            }
            if let value = usage.completionTokens {
                metadata["usage.output-tokens"] = String(value)
            }
            if let value = usage.totalTokens {
                metadata["usage.total-tokens"] = String(value)
            }
        }
        if let requestID = response.header(named: "x-request-id") {
            metadata["http.request-id"] = requestID
        }

        return LanguageModelResponse(
            content: choice.message.content ?? "",
            provider: providerIdentifier,
            metadata: metadata,
            toolCalls: toolCalls,
            usage: body.usage.map {
                LanguageModelUsage(
                    inputTokens: $0.promptTokens,
                    outputTokens: $0.completionTokens,
                    totalTokens: $0.totalTokens
                )
            },
            finishReason: choice.finishReason.map {
                LanguageModelFinishReason(rawValue: $0)
            }
        )
    }

    private func makeHTTPError(
        _ response: HTTPModelTransportResponse,
        attempts: Int
    ) -> OpenAICompatibleLanguageModelError {
        let envelope = try? JSONDecoder().decode(
            ErrorEnvelope.self,
            from: response.data
        )
        let code = envelope?.error.code
        let retryable =
            retryPolicy.retryableStatusCodes.contains(
                response.statusCode
            ) && code != "insufficient_quota"

        return .httpStatus(
            statusCode: response.statusCode,
            code: code,
            type: envelope?.error.type,
            message: includesProviderErrorMessages
                ? envelope?.error.message
                : nil,
            retryable: retryable,
            attempts: attempts
        )
    }

    private func validate(_ response: HTTPModelTransportResponse) throws {
        guard response.data.count <= resourceLimits.maximumResponseBodyBytes else {
            throw OpenAICompatibleLanguageModelError.responseBodyTooLarge(
                maximum: resourceLimits.maximumResponseBodyBytes
            )
        }
    }

    private func retryDelay(
        response: HTTPModelTransportResponse,
        failedAttempt: Int
    ) -> Double {
        if let value = response.header(named: "Retry-After"),
            let seconds = Double(value),
            seconds >= 0
        {
            return min(retryPolicy.maximumDelaySeconds, seconds)
        }
        return retryPolicy.delaySeconds(afterFailedAttempt: failedAttempt)
    }

    private static func isRetryableTransportError(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost,
            .dnsLookupFailed, .networkConnectionLost,
            .notConnectedToInternet, .internationalRoamingOff,
            .callIsActive, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isStructurallyValid(_ endpoint: URL) -> Bool {
        guard let scheme = endpoint.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            endpoint.host != nil,
            endpoint.user == nil,
            endpoint.password == nil,
            endpoint.fragment == nil
        else {
            return false
        }
        return true
    }

    private static func isAllowed(
        _ endpoint: URL,
        under policy: HTTPModelEndpointSecurityPolicy
    ) -> Bool {
        if endpoint.scheme?.lowercased() == "https" { return true }
        guard policy == .allowInsecureLoopback,
            let host = endpoint.host?.lowercased()
        else {
            return false
        }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }
}

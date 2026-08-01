/// Provider-neutral sampling options for text generation.
public enum LanguageModelSampling: Sendable, Equatable {
    case greedy
    case randomTopK(Int, seed: UInt64? = nil)
    case randomProbabilityThreshold(Double, seed: UInt64? = nil)
}

/// Provider-neutral controls for one language-model request.
public struct LanguageModelGenerationOptions: Sendable, Equatable {
    public var sampling: LanguageModelSampling?
    public var temperature: Double?
    public var maximumResponseTokens: Int?

    public init(
        sampling: LanguageModelSampling? = nil,
        temperature: Double? = nil,
        maximumResponseTokens: Int? = nil
    ) {
        self.sampling = sampling
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
    }

    public static let `default` = LanguageModelGenerationOptions()
}

/// A provider-neutral request for generated text.
public struct LanguageModelRequest: Sendable, Equatable {
    public var prompt: String
    public var instructions: String?
    public var options: LanguageModelGenerationOptions
    public var routingPolicy: LanguageModelRoutingPolicy
    public var requiredCapabilities: Set<LanguageModelCapability>
    public var input: [LanguageModelInputPart]
    public var messages: [LanguageModelMessage]
    public var tools: [LanguageModelToolDefinition]
    public var toolChoice: LanguageModelToolChoice?
    public var parallelToolCalls: Bool?
    public var toolAccessPolicy: LanguageModelToolAccessPolicy?
    public var responseFormat: LanguageModelResponseFormat?

    public init(
        prompt: String,
        instructions: String? = nil,
        options: LanguageModelGenerationOptions = .default,
        routingPolicy: LanguageModelRoutingPolicy = .automatic,
        requiredCapabilities: Set<LanguageModelCapability> = [],
        input: [LanguageModelInputPart] = [],
        messages: [LanguageModelMessage] = [],
        tools: [LanguageModelToolDefinition] = [],
        toolChoice: LanguageModelToolChoice? = nil,
        parallelToolCalls: Bool? = nil,
        toolAccessPolicy: LanguageModelToolAccessPolicy? = nil,
        responseFormat: LanguageModelResponseFormat? = nil
    ) {
        self.prompt = prompt
        self.instructions = instructions
        self.options = options
        self.routingPolicy = routingPolicy
        self.requiredCapabilities = requiredCapabilities
        self.input = input
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.toolAccessPolicy = toolAccessPolicy
        self.responseFormat = responseFormat
    }
}

/// A provider-neutral text-generation response.
public struct LanguageModelUsage: Sendable, Equatable, Codable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

/// A provider-neutral, forward-compatible generation finish reason.
public struct LanguageModelFinishReason: RawRepresentable, Sendable,
    Equatable, Codable, ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public static let stop = LanguageModelFinishReason(rawValue: "stop")
    public static let length = LanguageModelFinishReason(rawValue: "length")
    public static let toolCalls = LanguageModelFinishReason(rawValue: "tool_calls")
    public static let contentFilter = LanguageModelFinishReason(rawValue: "content_filter")
}

/// A provider-neutral text-generation response.
public struct LanguageModelResponse: Sendable, Equatable {
    public var content: String
    public var provider: String?
    public var metadata: [String: String]
    public var routingReport: LanguageModelRoutingReport?
    public var toolCalls: [LanguageModelToolCall]
    public var toolExecutionReport: LanguageModelToolExecutionReport?
    public var usage: LanguageModelUsage?
    public var finishReason: LanguageModelFinishReason?

    public init(
        content: String,
        provider: String? = nil,
        metadata: [String: String] = [:],
        routingReport: LanguageModelRoutingReport? = nil,
        toolCalls: [LanguageModelToolCall] = [],
        toolExecutionReport: LanguageModelToolExecutionReport? = nil,
        usage: LanguageModelUsage? = nil,
        finishReason: LanguageModelFinishReason? = nil
    ) {
        self.content = content
        self.provider = provider
        self.metadata = metadata
        self.routingReport = routingReport
        self.toolCalls = toolCalls
        self.toolExecutionReport = toolExecutionReport
        self.usage = usage
        self.finishReason = finishReason
    }
}

/// A text-generating model that can be used by workflow nodes.
public protocol WorkflowLanguageModel: Sendable {
    func generate(
        _ request: LanguageModelRequest
    ) async throws -> LanguageModelResponse
}

/// A closure-backed model useful for tests and lightweight integrations.
public struct ClosureLanguageModel: WorkflowLanguageModel {
    private let operation:
        @Sendable (
            LanguageModelRequest
        ) async throws -> LanguageModelResponse

    public init(
        generate:
            @escaping @Sendable (
                LanguageModelRequest
            ) async throws -> LanguageModelResponse
    ) {
        operation = generate
    }

    public func generate(
        _ request: LanguageModelRequest
    ) async throws -> LanguageModelResponse {
        try await operation(request)
    }
}

/// A provider-neutral model that always returns the same response content.
public struct StaticLanguageModel: WorkflowLanguageModel {
    public let content: String
    public let provider: String?
    public let metadata: [String: String]

    public init(
        content: String,
        provider: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.content = content
        self.provider = provider
        self.metadata = metadata
    }

    public func generate(
        _ request: LanguageModelRequest
    ) async throws -> LanguageModelResponse {
        LanguageModelResponse(
            content: content,
            provider: provider,
            metadata: metadata
        )
    }
}

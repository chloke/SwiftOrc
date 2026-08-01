import Foundation

/// Whether an application must approve a tool call before it executes.
public enum LanguageModelToolApprovalRequirement: Sendable, Equatable {
    case never
    case always
}

/// The application-level result of reviewing a proposed tool call.
public enum LanguageModelToolApprovalDecision: Sendable, Equatable {
    case approved
    case denied
}

/// A proposed tool invocation sent only to the configured approval handler.
///
/// Unlike diagnostic events, this value contains the raw arguments so an
/// application can present a meaningful confirmation UI. Applications should
/// treat those arguments as potentially sensitive and untrusted.
public struct LanguageModelToolApprovalRequest: Sendable, Equatable {
    public let call: LanguageModelToolCall
    public let provider: String?

    public init(call: LanguageModelToolCall, provider: String?) {
        self.call = call
        self.provider = provider
    }
}

public typealias LanguageModelToolApprovalHandler =
    @Sendable (
        LanguageModelToolApprovalRequest
    ) async -> LanguageModelToolApprovalDecision

/// Information passed to an optional retry filter after an attempt fails.
public struct LanguageModelToolRetryRequest: Sendable, Equatable {
    public let tool: String
    public let attempt: Int
    public let failure: WorkflowFailure

    public init(tool: String, attempt: Int, failure: WorkflowFailure) {
        self.tool = tool
        self.attempt = attempt
        self.failure = failure
    }
}

public typealias LanguageModelToolRetryHandler =
    @Sendable (
        LanguageModelToolRetryRequest
    ) async -> Bool

/// Retry behavior for a single tool invocation.
public struct LanguageModelToolRetryPolicy: Sendable {
    public var maximumAttempts: Int
    public var delay: Duration
    public var shouldRetry: LanguageModelToolRetryHandler?

    public init(
        maximumAttempts: Int = 1,
        delay: Duration = .zero,
        shouldRetry: LanguageModelToolRetryHandler? = nil
    ) {
        self.maximumAttempts = maximumAttempts
        self.delay = delay
        self.shouldRetry = shouldRetry
    }

    public static let none = LanguageModelToolRetryPolicy()
}

/// Per-tool safety and reliability controls.
public struct LanguageModelToolExecutionPolicy: Sendable {
    public var approval: LanguageModelToolApprovalRequirement
    public var timeout: Duration?
    public var retry: LanguageModelToolRetryPolicy

    public init(
        approval: LanguageModelToolApprovalRequirement = .never,
        timeout: Duration? = nil,
        retry: LanguageModelToolRetryPolicy = .none
    ) {
        self.approval = approval
        self.timeout = timeout
        self.retry = retry
    }

    public static let `default` = LanguageModelToolExecutionPolicy()
}

/// A callable tool paired with the policy enforced whenever it executes.
public struct LanguageModelToolRegistration: Sendable {
    public let definition: LanguageModelToolDefinition
    public let policy: LanguageModelToolExecutionPolicy
    public let metadata: LanguageModelToolMetadata

    let tool: AnyLanguageModelTool

    public init<Tool: LanguageModelTool>(
        tool: Tool,
        policy: LanguageModelToolExecutionPolicy = .default,
        metadata: LanguageModelToolMetadata = .unclassified
    ) {
        let erased = AnyLanguageModelTool(tool)
        definition = erased.definition
        self.policy = policy
        self.metadata = metadata
        self.tool = erased
    }
}

/// Provider and trace information associated with one local invocation.
package struct LanguageModelToolExecutionContext: Sendable, Equatable {
    package let round: Int
    package let callNumber: Int
    package let provider: String?

    package init(round: Int, callNumber: Int, provider: String?) {
        self.round = round
        self.callNumber = callNumber
        self.provider = provider
    }
}

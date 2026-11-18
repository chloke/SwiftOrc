import Foundation

/// What kind of answer a node is waiting for. Applications can define their
/// own kinds; the built-in ones are suggestions for common UI.
public struct WorkflowInputKind: RawRepresentable, Hashable, Sendable, Codable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public var description: String { rawValue }

    public static let text: Self = "text"
    public static let confirmation: Self = "confirmation"
    public static let choice: Self = "choice"
}

/// A question a node asks before the workflow can continue.
///
/// The request is saved in the suspension checkpoint, so it survives the app
/// being closed. Workflow events only carry its identifier and kind; the
/// prompt, choices, and metadata stay out of traces.
public struct WorkflowInputRequest: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public var kind: WorkflowInputKind
    public var prompt: String?
    public var choices: [String]
    public var metadata: [String: String]
    /// After this date, answers are rejected with
    /// ``WorkflowError/inputRequestExpired(_:)``.
    public var expiresAt: Date?

    public init(
        id: UUID = UUID(),
        kind: WorkflowInputKind = .text,
        prompt: String? = nil,
        choices: [String] = [],
        metadata: [String: String] = [:],
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.prompt = prompt
        self.choices = choices
        self.metadata = metadata
        self.expiresAt = expiresAt
    }
}

/// The answer delivered to the node that runs first after a resume.
public struct WorkflowInputResponse: Sendable, Equatable, Codable {
    public let request: WorkflowInputRequest
    /// The optional generic answer passed to `resume(from:answering:with:)`.
    /// Applications that prefer typed state write the answer into state with
    /// the resume call's update closure instead.
    public let value: JSONValue?
    public let respondedAt: Date

    public init(
        request: WorkflowInputRequest,
        value: JSONValue?,
        respondedAt: Date = Date()
    ) {
        self.request = request
        self.value = value
        self.respondedAt = respondedAt
    }
}

/// Thrown by `run` and `resume` overloads that return a ``WorkflowRun`` when a
/// node asks for input. It carries everything needed to continue later.
///
/// The budgeted overloads return ``WorkflowExecutionResult/suspended(_:)``
/// instead of throwing.
public struct WorkflowInputRequired<State: Sendable>: Error, Sendable {
    public let continuation: WorkflowContinuation<State>

    public init(continuation: WorkflowContinuation<State>) {
        self.continuation = continuation
    }

    /// The question the workflow is waiting on.
    public var request: WorkflowInputRequest? {
        continuation.checkpoint.pendingInput
    }
}

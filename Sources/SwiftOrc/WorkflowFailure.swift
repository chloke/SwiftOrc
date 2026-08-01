/// A sendable, inspectable description of a failure encountered by a workflow.
public struct WorkflowFailure: Error, Sendable, Equatable, Codable {
    public enum Kind: Sendable, Equatable, Codable {
        case execution
        case validation
        case timeout
        case routing
        case limit
        case configuration
    }

    public let kind: Kind
    public let message: String
    public let errorType: String

    public init(kind: Kind, message: String, errorType: String) {
        self.kind = kind
        self.message = message
        self.errorType = errorType
    }

    public init(error: any Error) {
        if let executionError = error as? WorkflowExecutionError {
            self = executionError.failure
            return
        }

        if let failure = error as? WorkflowFailure {
            self = failure
            return
        }

        kind = Self.kind(for: error)
        errorType = String(reflecting: type(of: error))

        // Error descriptions may contain prompts, model-controlled values,
        // URLs, or application data. Module ownership is not a security
        // boundary: framework error cases can still carry untrusted strings.
        // Preserve a message only when an application deliberately supplied an
        // already-reviewed WorkflowFailure above.
        message = "The operation failed."
    }

    private static func kind(for error: any Error) -> Kind {
        guard let workflowError = error as? WorkflowError else {
            return .execution
        }

        switch workflowError {
        case .nodeTimedOut:
            return .timeout
        case .validationFailed:
            return .validation
        case .transitionTargetNotFound:
            return .routing
        case .stepLimitExceeded, .retryLimitExceeded:
            return .limit
        case .noNodes, .duplicateNodeID, .initialNodeNotFound,
            .declaredDestinationNotFound,
            .parallelNodeHasNoBranches, .invalidParallelConcurrency,
            .duplicateParallelBranchName,
            .unsupportedCheckpointVersion, .checkpointDefinitionMismatch,
            .checkpointNodeNotFound, .invalidCheckpointAttempt,
            .invalidCheckpointSteps,
            .invalidMaximumSteps, .invalidMaximumRetriesPerNode:
            return .configuration
        }
    }
}

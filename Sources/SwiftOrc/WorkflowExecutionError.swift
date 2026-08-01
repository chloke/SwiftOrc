import Foundation

/// A recovery transition taken during an otherwise successful workflow run.
public struct WorkflowRecovery: Sendable, Equatable, Codable {
    public let node: NodeID
    public let target: NodeID
    public let failure: WorkflowFailure

    public init(node: NodeID, target: NodeID, failure: WorkflowFailure) {
        self.node = node
        self.target = target
        self.failure = failure
    }
}

/// Describes whether a workflow completed normally or through recovery paths.
public enum WorkflowOutcome: Sendable, Equatable {
    case completed
    case recovered([WorkflowRecovery])

    public var recoveries: [WorkflowRecovery] {
        switch self {
        case .completed:
            return []
        case let .recovered(recoveries):
            return recoveries
        }
    }

    public var wasRecovered: Bool {
        !recoveries.isEmpty
    }
}

/// A structured report for a workflow that stopped without reaching `finish`.
public struct WorkflowExecutionError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    public let executionID: UUID
    public let node: NodeID
    public let steps: Int
    public let failure: WorkflowFailure
    public let workflowError: WorkflowError?
    public let events: [WorkflowEvent]

    public var description: String {
        "Workflow failed at \(node) after \(steps) step(s): \(failure.message)"
    }

    init(
        capturing error: any Error,
        executionID: UUID,
        node: NodeID,
        steps: Int,
        events: [WorkflowEvent]
    ) {
        if let executionError = error as? WorkflowExecutionError {
            failure = executionError.failure
            workflowError = executionError.workflowError
        } else {
            failure = WorkflowFailure(error: error)
            workflowError = error as? WorkflowError
        }

        self.executionID = executionID
        self.node = node
        self.steps = steps
        self.events = events
    }
}

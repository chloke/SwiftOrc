import Foundation

/// The kind of transition produced by a completed node.
public enum WorkflowTransitionKind: Sendable, Equatable, Codable {
    case next(NodeID)
    case retry
    case fallback(NodeID)
    case finish
}

/// Structured diagnostics attached to a completed node result.
public enum WorkflowAnnotation: Sendable, Equatable, Codable {
    case languageModelRouting(LanguageModelRoutingReport)
    case languageModelTools(LanguageModelToolExecutionReport)
}

/// An observable event emitted during workflow execution.
public enum WorkflowEvent: Sendable, Equatable, Codable {
    case started(executionID: UUID, initialNode: NodeID)
    case resumed(
        executionID: UUID,
        node: NodeID,
        attempt: Int,
        steps: Int
    )
    case checkpointCreated(
        executionID: UUID,
        nextNode: NodeID,
        attempt: Int,
        steps: Int
    )
    case nodeStarted(node: NodeID, attempt: Int, step: Int)
    case nodeCompleted(node: NodeID, transition: WorkflowTransitionKind)
    case branchSelected(node: NodeID, route: String, target: NodeID)
    case parallelBranchesCompleted(node: NodeID, branches: [String])
    case annotation(node: NodeID, value: WorkflowAnnotation)
    case retryScheduled(node: NodeID, nextAttempt: Int, reason: WorkflowFailure?)
    case fallbackSelected(node: NodeID, target: NodeID, failure: WorkflowFailure)
    case nodeFailed(node: NodeID, failure: WorkflowFailure)
    case workflowFailed(
        executionID: UUID,
        node: NodeID,
        failure: WorkflowFailure,
        steps: Int
    )
    case cancelled(node: NodeID)
    case finished(executionID: UUID, finalNode: NodeID, steps: Int)
}

/// Receives workflow events as they occur.
public typealias WorkflowEventHandler = @Sendable (WorkflowEvent) async -> Void

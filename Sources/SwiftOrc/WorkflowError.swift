/// Errors produced by workflow definition validation or graph execution.
public enum WorkflowError: Error, Sendable, Equatable {
    case noNodes
    case duplicateNodeID(NodeID)
    case initialNodeNotFound(NodeID)
    case declaredDestinationNotFound(from: NodeID, target: NodeID)
    case parallelNodeHasNoBranches(NodeID)
    case invalidParallelConcurrency(node: NodeID, maximum: Int)
    case duplicateParallelBranchName(node: NodeID, name: String)
    case unsupportedCheckpointVersion(Int)
    case checkpointDefinitionMismatch(
        expected: WorkflowDefinitionID,
        actual: WorkflowDefinitionID
    )
    case checkpointNodeNotFound(NodeID)
    case invalidCheckpointAttempt(Int)
    case invalidCheckpointSteps(Int)
    case invalidMaximumSteps(Int)
    case invalidMaximumRetriesPerNode(Int)
    case transitionTargetNotFound(from: NodeID, target: NodeID)
    case stepLimitExceeded(limit: Int)
    case retryLimitExceeded(node: NodeID, limit: Int)
    case nodeTimedOut(node: NodeID, timeout: Duration)
    case validationFailed(node: NodeID, reason: String)
}

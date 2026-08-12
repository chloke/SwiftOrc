import Foundation

/// Per-invocation limits that allow a workflow to yield at a safe node boundary.
///
/// These limits are distinct from ``WorkflowConfiguration/maximumSteps``.
/// The configuration limit is a cumulative safety cap for the complete workflow,
/// while an execution budget resets each time a workflow is started or resumed.
public struct WorkflowExecutionBudget: Sendable, Equatable {
    /// Maximum node executions allowed during this invocation.
    ///
    /// A value of `nil` does not impose a per-invocation node limit. A supplied
    /// value must be greater than zero.
    public var maximumNodeExecutions: Int?

    /// A monotonic deadline checked between node executions.
    ///
    /// A node that has already started is allowed to finish. The runtime yields
    /// before starting the next node when this deadline has been reached.
    public var deadline: ContinuousClock.Instant?

    public init(
        maximumNodeExecutions: Int? = nil,
        deadline: ContinuousClock.Instant? = nil
    ) {
        self.maximumNodeExecutions = maximumNodeExecutions
        self.deadline = deadline
    }

    /// An execution budget with no per-invocation limits.
    public static let unlimited = WorkflowExecutionBudget()
}

/// A configuration error detected before budgeted execution starts.
public enum WorkflowExecutionBudgetError: Error, Sendable, Equatable {
    case invalidMaximumNodeExecutions(Int)
}

/// Why a budgeted workflow yielded before reaching a finish transition.
public enum WorkflowSuspensionReason: Sendable, Equatable, Codable {
    case maximumNodeExecutionsReached(limit: Int)
    case deadlineReached
}

/// Durable information required to continue a budgeted workflow.
public struct WorkflowContinuation<State: Sendable>: Sendable {
    /// The safe-boundary snapshot from which the workflow can resume.
    public let checkpoint: WorkflowCheckpoint<State>

    /// The budget condition that caused this invocation to yield.
    public let reason: WorkflowSuspensionReason

    /// Number of node executions performed during the invocation that yielded.
    public let nodeExecutions: Int

    public init(
        checkpoint: WorkflowCheckpoint<State>,
        reason: WorkflowSuspensionReason,
        nodeExecutions: Int
    ) {
        self.checkpoint = checkpoint
        self.reason = reason
        self.nodeExecutions = nodeExecutions
    }
}

extension WorkflowContinuation: Codable where State: Codable {}

/// The successful result of a budgeted workflow invocation.
public enum WorkflowExecutionResult<State: Sendable>: Sendable {
    /// The workflow reached a finish transition.
    case completed(WorkflowRun<State>)

    /// The invocation exhausted its budget at a safe node boundary.
    case suspended(WorkflowContinuation<State>)
}

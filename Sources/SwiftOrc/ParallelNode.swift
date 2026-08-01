/// The action taken after a parallel node merges all branch results.
public enum ParallelContinuation: Sendable, Equatable {
    case next(NodeID)
    case finish
}

/// One independent operation executed by a ``ParallelNode``.
public struct ParallelBranch<State: Sendable>: Sendable {
    public let name: String

    private let operation:
        @Sendable (
            State,
            WorkflowContext
        ) async throws -> State

    public init(
        _ name: String,
        run:
            @escaping @Sendable (
                State,
                WorkflowContext
            ) async throws -> State
    ) {
        self.name = name
        operation = run
    }

    func execute(
        state: State,
        context: WorkflowContext
    ) async throws -> State {
        try await operation(state, context)
    }
}

/// The state produced by one named parallel branch.
public struct ParallelBranchResult<State: Sendable>: Sendable {
    public let name: String
    public let state: State

    public init(name: String, state: State) {
        self.name = name
        self.state = state
    }
}

/// Branch results ordered exactly as their branches were declared.
public struct ParallelResults<State: Sendable>: Sendable {
    public let ordered: [ParallelBranchResult<State>]

    public init(_ ordered: [ParallelBranchResult<State>]) {
        self.ordered = ordered
    }

    public subscript(branch name: String) -> State? {
        ordered.first { $0.name == name }?.state
    }
}

/// A structured failure identifying the parallel branch that threw an error.
public struct ParallelBranchExecutionError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    public let node: NodeID
    public let branch: String
    public let failure: WorkflowFailure

    public init(node: NodeID, branch: String, failure: WorkflowFailure) {
        self.node = node
        self.branch = branch
        self.failure = failure
    }

    public var description: String {
        "Parallel branch '\(branch)' in node '\(node)' failed: \(failure.message)"
    }
}

/// Runs independent state transformations concurrently and merges their output.
///
/// Every branch receives the same input state. Results are passed to `merge` in
/// declaration order, regardless of completion order, so merging is
/// deterministic. If one branch fails, its siblings are cancelled.
public struct ParallelNode<State: Sendable>: WorkflowNode {
    public let id: NodeID
    public let branches: [ParallelBranch<State>]
    public let continuation: ParallelContinuation
    public let maximumConcurrentBranches: Int

    private let merge:
        @Sendable (
            State,
            ParallelResults<State>,
            WorkflowContext
        ) async throws -> State

    public var declaredDestinations: Set<NodeID> {
        switch continuation {
        case let .next(target): [target]
        case .finish: []
        }
    }

    public init(
        id: NodeID,
        branches: [ParallelBranch<State>],
        continuation: ParallelContinuation,
        maximumConcurrentBranches: Int = 4,
        merge:
            @escaping @Sendable (
                State,
                ParallelResults<State>,
                WorkflowContext
            ) async throws -> State
    ) throws {
        guard !branches.isEmpty else {
            throw WorkflowError.parallelNodeHasNoBranches(id)
        }
        guard maximumConcurrentBranches >= 1 else {
            throw WorkflowError.invalidParallelConcurrency(
                node: id,
                maximum: maximumConcurrentBranches
            )
        }

        var names: Set<String> = []
        for branch in branches {
            guard names.insert(branch.name).inserted else {
                throw WorkflowError.duplicateParallelBranchName(
                    node: id,
                    name: branch.name
                )
            }
        }

        self.id = id
        self.branches = branches
        self.continuation = continuation
        self.maximumConcurrentBranches = maximumConcurrentBranches
        self.merge = merge
    }

    public func run(
        state: State,
        context: WorkflowContext
    ) async throws -> NodeResult<State> {
        let completed = try await withThrowingTaskGroup(
            of: IndexedParallelResult<State>.self,
            returning: [IndexedParallelResult<State>].self
        ) { group in
            let initialCount = min(maximumConcurrentBranches, branches.count)
            for index in 0..<initialCount {
                addBranchTask(index, to: &group, state: state, context: context)
            }

            var completed: [IndexedParallelResult<State>] = []
            for try await result in group {
                completed.append(result)
                let nextIndex = completed.count + initialCount - 1
                if nextIndex < branches.count {
                    addBranchTask(
                        nextIndex,
                        to: &group,
                        state: state,
                        context: context
                    )
                }
            }
            return completed.sorted { $0.index < $1.index }
        }

        try Task.checkCancellation()
        let results = ParallelResults(completed.map(\.result))
        let mergedState = try await merge(state, results, context)

        return .parallel(
            mergedState,
            continuation: continuation,
            branches: results.ordered.map(\.name)
        )
    }

    private func addBranchTask(
        _ index: Int,
        to group: inout ThrowingTaskGroup<IndexedParallelResult<State>, any Error>,
        state: State,
        context: WorkflowContext
    ) {
        let branch = branches[index]
        group.addTask {
            do {
                try Task.checkCancellation()
                let branchState = try await branch.execute(
                    state: state,
                    context: context
                )
                try Task.checkCancellation()
                return IndexedParallelResult(
                    index: index,
                    result: ParallelBranchResult(
                        name: branch.name,
                        state: branchState
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ParallelBranchExecutionError(
                    node: id,
                    branch: branch.name,
                    failure: WorkflowFailure(error: error)
                )
            }
        }
    }
}

private struct IndexedParallelResult<State: Sendable>: Sendable {
    let index: Int
    let result: ParallelBranchResult<State>
}

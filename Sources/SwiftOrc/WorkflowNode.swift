/// The decision returned after a node finishes executing.
public enum NodeResult<State: Sendable>: Sendable {
    /// Attaches structured diagnostics while preserving another node result.
    indirect case annotated(NodeResult<State>, WorkflowAnnotation)

    /// Continue execution at another node.
    case next(State, NodeID)

    /// Continue at a destination selected by a named branch route.
    case route(State, NodeID, name: String)

    /// Continue after concurrently executing and merging named branches.
    case parallel(
        State,
        continuation: ParallelContinuation,
        branches: [String]
    )

    /// Execute the current node again, subject to the workflow retry limit.
    case retry(State, reason: WorkflowFailure? = nil)

    /// Route to a recovery node after a failure.
    case fallback(State, NodeID, failure: WorkflowFailure)

    /// Finish the workflow successfully.
    case finish(State)
}

/// A unit of work in a workflow graph.
public protocol WorkflowNode<State>: Sendable {
    associatedtype State: Sendable

    var id: NodeID { get }

    /// Destinations known when the workflow graph is constructed.
    ///
    /// The workflow validates these targets before execution begins. Nodes
    /// with fully dynamic transitions can use the default empty collection
    /// and continue to rely on runtime transition validation.
    var declaredDestinations: Set<NodeID> { get }

    func run(
        state: State,
        context: WorkflowContext
    ) async throws -> NodeResult<State>
}

public extension WorkflowNode {
    var declaredDestinations: Set<NodeID> { [] }
}

/// A type-erased workflow node that allows heterogeneous node types in one graph.
public struct AnyWorkflowNode<State: Sendable>: Sendable {
    public let id: NodeID
    public let declaredDestinations: Set<NodeID>

    private let operation:
        @Sendable (
            State,
            WorkflowContext
        ) async throws -> NodeResult<State>

    public init<Node: WorkflowNode>(_ node: Node) where Node.State == State {
        id = node.id
        declaredDestinations = node.declaredDestinations
        operation = node.run
    }

    public init(
        id: NodeID,
        declaredDestinations: Set<NodeID> = [],
        run:
            @escaping @Sendable (
                State,
                WorkflowContext
            ) async throws -> NodeResult<State>
    ) {
        self.id = id
        self.declaredDestinations = declaredDestinations
        operation = run
    }

    func run(
        state: State,
        context: WorkflowContext
    ) async throws -> NodeResult<State> {
        try await operation(state, context)
    }
}

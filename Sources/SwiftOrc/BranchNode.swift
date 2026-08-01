/// A named conditional path from a ``BranchNode`` to another workflow node.
public struct BranchRoute<State: Sendable>: Sendable {
    public let name: String
    public let target: NodeID

    private let predicate:
        @Sendable (
            State,
            WorkflowContext
        ) async throws -> Bool

    public init(
        _ name: String,
        to target: NodeID,
        when predicate:
            @escaping @Sendable (
                State,
                WorkflowContext
            ) async throws -> Bool
    ) {
        self.name = name
        self.target = target
        self.predicate = predicate
    }

    func matches(
        _ state: State,
        context: WorkflowContext
    ) async throws -> Bool {
        try await predicate(state, context)
    }
}

/// Selects the first matching named route, or its required default route.
///
/// Every possible destination is declared to the workflow, so missing branch
/// targets are reported when the graph is constructed rather than midway
/// through execution.
public struct BranchNode<State: Sendable>: WorkflowNode {
    public let id: NodeID
    public let routes: [BranchRoute<State>]
    public let defaultTarget: NodeID
    public let defaultRouteName: String

    public var declaredDestinations: Set<NodeID> {
        Set(routes.map(\.target)).union([defaultTarget])
    }

    public init(
        id: NodeID,
        routes: [BranchRoute<State>],
        defaultTarget: NodeID,
        defaultRouteName: String = "default"
    ) {
        self.id = id
        self.routes = routes
        self.defaultTarget = defaultTarget
        self.defaultRouteName = defaultRouteName
    }

    public func run(
        state: State,
        context: WorkflowContext
    ) async throws -> NodeResult<State> {
        for route in routes {
            if try await route.matches(state, context: context) {
                return .route(state, route.target, name: route.name)
            }
        }

        return .route(state, defaultTarget, name: defaultRouteName)
    }
}

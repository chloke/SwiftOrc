/// A reusable collection of nodes that can be embedded in a parent workflow.
///
/// Components are flattened into the parent graph. Their nodes therefore use
/// the parent's execution identifier, step budget, cancellation, recovery
/// tracking, and event trace.
public struct WorkflowComponent<State: Sendable>: Sendable {
    /// The node a parent workflow should use to enter this component.
    public let entryNode: NodeID

    let nodes: [AnyWorkflowNode<State>]

    /// All node identifiers contributed to the parent workflow.
    public var nodeIDs: Set<NodeID> {
        Set(nodes.map(\.id))
    }

    public init(
        entryNode: NodeID,
        nodes: [AnyWorkflowNode<State>]
    ) throws {
        guard !nodes.isEmpty else {
            throw WorkflowError.noNodes
        }

        var identifiers: Set<NodeID> = []
        for node in nodes {
            guard identifiers.insert(node.id).inserted else {
                throw WorkflowError.duplicateNodeID(node.id)
            }
        }

        guard identifiers.contains(entryNode) else {
            throw WorkflowError.initialNodeNotFound(entryNode)
        }

        self.entryNode = entryNode
        self.nodes = nodes
    }

    /// Creates a reusable component using declarative node syntax.
    public init(
        entryNode: NodeID,
        @WorkflowBuilder<State> nodes: () -> [AnyWorkflowNode<State>]
    ) throws {
        try self.init(entryNode: entryNode, nodes: nodes())
    }

    /// Prefixes this component's node identifiers and internal transitions.
    ///
    /// Namespacing lets multiple instances of the same component coexist in a
    /// workflow without identifier collisions. Transitions to nodes outside
    /// the component are left unchanged.
    public func namespaced(_ namespace: String) -> WorkflowComponent<State> {
        let identifiers = nodeIDs
        let mapping = Dictionary(
            uniqueKeysWithValues: identifiers.map { id in
                (id, NodeID(rawValue: "\(namespace).\(id.rawValue)"))
            })

        return remappingNodes(mapping) { result in
            result.remappingDestinations(using: mapping)
        }
    }

    /// Continues at `target` whenever a node would otherwise finish.
    ///
    /// This allows a self-contained component to become one stage in a larger
    /// workflow without changing the component's original nodes.
    public func continuing(to target: NodeID) -> WorkflowComponent<State> {
        remappingNodes(
            [:],
            transformResult: { $0.continuing(to: target) },
            addingDeclaredDestination: target
        )
    }

    private init(
        uncheckedEntryNode entryNode: NodeID,
        nodes: [AnyWorkflowNode<State>]
    ) {
        self.entryNode = entryNode
        self.nodes = nodes
    }

    private func remappingNodes(
        _ identifiers: [NodeID: NodeID],
        transformResult:
            @escaping @Sendable (
                NodeResult<State>
            ) -> NodeResult<State>,
        addingDeclaredDestination additionalDestination: NodeID? = nil
    ) -> WorkflowComponent<State> {
        let remappedNodes = nodes.map { node in
            var destinations = Set(
                node.declaredDestinations.map {
                    identifiers[$0] ?? $0
                })
            if let additionalDestination {
                destinations.insert(additionalDestination)
            }

            return AnyWorkflowNode(
                id: identifiers[node.id] ?? node.id,
                declaredDestinations: destinations
            ) { state, context in
                let result = try await node.run(state: state, context: context)
                return transformResult(result)
            }
        }

        return WorkflowComponent(
            uncheckedEntryNode: identifiers[entryNode] ?? entryNode,
            nodes: remappedNodes
        )
    }
}

private extension NodeResult {
    func remappingDestinations(
        using identifiers: [NodeID: NodeID]
    ) -> NodeResult<State> {
        switch self {
        case let .annotated(result, annotation):
            return .annotated(
                result.remappingDestinations(using: identifiers),
                annotation
            )
        case let .next(state, target):
            return .next(state, identifiers[target] ?? target)
        case let .route(state, target, name):
            return .route(
                state,
                identifiers[target] ?? target,
                name: name
            )
        case let .parallel(state, continuation, branches):
            let remappedContinuation: ParallelContinuation
            switch continuation {
            case let .next(target):
                remappedContinuation = .next(identifiers[target] ?? target)
            case .finish:
                remappedContinuation = .finish
            }
            return .parallel(
                state,
                continuation: remappedContinuation,
                branches: branches
            )
        case let .retry(state, reason):
            return .retry(state, reason: reason)
        case let .fallback(state, target, failure):
            return .fallback(
                state,
                identifiers[target] ?? target,
                failure: failure
            )
        case let .finish(state):
            return .finish(state)
        }
    }

    func continuing(to target: NodeID) -> NodeResult<State> {
        switch self {
        case let .annotated(result, annotation):
            return .annotated(result.continuing(to: target), annotation)
        case let .finish(state):
            return .next(state, target)
        case let .parallel(state, continuation, branches):
            guard continuation == .finish else { return self }
            return .parallel(
                state,
                continuation: .next(target),
                branches: branches
            )
        case .next, .route, .retry, .fallback:
            return self
        }
    }
}

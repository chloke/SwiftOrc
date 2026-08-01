import Foundation

/// The successful result of a workflow execution.
public struct WorkflowRun<State: Sendable>: Sendable {
    public let state: State
    public let executionID: UUID
    public let finalNode: NodeID
    public let steps: Int
    public let events: [WorkflowEvent]
    public let outcome: WorkflowOutcome
}

/// An executable graph of asynchronous nodes sharing one strongly typed state.
public struct Workflow<State: Sendable>: Sendable {
    public let definitionID: WorkflowDefinitionID
    public let initialNode: NodeID
    public let configuration: WorkflowConfiguration

    let nodes: [NodeID: AnyWorkflowNode<State>]

    public init(
        definitionID: WorkflowDefinitionID? = nil,
        initialNode: NodeID,
        nodes: [AnyWorkflowNode<State>],
        configuration: WorkflowConfiguration = .default
    ) throws {
        guard !nodes.isEmpty else {
            throw WorkflowError.noNodes
        }
        guard configuration.maximumSteps > 0 else {
            throw WorkflowError.invalidMaximumSteps(configuration.maximumSteps)
        }
        guard configuration.maximumRetriesPerNode >= 0 else {
            throw WorkflowError.invalidMaximumRetriesPerNode(
                configuration.maximumRetriesPerNode
            )
        }

        var nodesByID: [NodeID: AnyWorkflowNode<State>] = [:]
        for node in nodes {
            guard nodesByID[node.id] == nil else {
                throw WorkflowError.duplicateNodeID(node.id)
            }
            nodesByID[node.id] = node
        }

        guard nodesByID[initialNode] != nil else {
            throw WorkflowError.initialNodeNotFound(initialNode)
        }

        for node in nodes {
            let destinations = node.declaredDestinations.sorted {
                $0.rawValue < $1.rawValue
            }
            for target in destinations where nodesByID[target] == nil {
                throw WorkflowError.declaredDestinationNotFound(
                    from: node.id,
                    target: target
                )
            }
        }

        self.definitionID =
            definitionID
            ?? Self.derivedDefinitionID(
                initialNode: initialNode,
                nodes: nodes,
                configuration: configuration
            )
        self.initialNode = initialNode
        self.configuration = configuration
        self.nodes = nodesByID
    }

    /// Creates a workflow using declarative node collection syntax.
    public init(
        definitionID: WorkflowDefinitionID? = nil,
        initialNode: NodeID,
        configuration: WorkflowConfiguration = .default,
        @WorkflowBuilder<State> nodes: () -> [AnyWorkflowNode<State>]
    ) throws {
        try self.init(
            definitionID: definitionID,
            initialNode: initialNode,
            nodes: nodes(),
            configuration: configuration
        )
    }

    public func run(
        _ initialState: State,
        onEvent: WorkflowEventHandler? = nil,
        onCheckpoint: WorkflowCheckpointHandler<State>? = nil,
        artifactStore: (any WorkflowArtifactStore)? = nil
    ) async throws -> WorkflowRun<State> {
        let executionID = UUID()
        let started = WorkflowEvent.started(
            executionID: executionID,
            initialNode: initialNode
        )
        await onEvent?(started)

        return try await execute(
            state: initialState,
            executionID: executionID,
            currentNodeID: initialNode,
            attempt: 1,
            steps: 0,
            events: [started],
            recoveries: [],
            artifactStore: artifactStore,
            onCheckpoint: onCheckpoint,
            onEvent: onEvent
        )
    }

    /// Continues execution from a previously emitted safe-boundary snapshot.
    public func resume(
        from checkpoint: WorkflowCheckpoint<State>,
        onEvent: WorkflowEventHandler? = nil,
        onCheckpoint: WorkflowCheckpointHandler<State>? = nil,
        artifactStore: (any WorkflowArtifactStore)? = nil
    ) async throws -> WorkflowRun<State> {
        try validate(checkpoint)

        let resumed = WorkflowEvent.resumed(
            executionID: checkpoint.executionID,
            node: checkpoint.nextNode,
            attempt: checkpoint.attempt,
            steps: checkpoint.steps
        )
        await onEvent?(resumed)

        return try await execute(
            state: checkpoint.state,
            executionID: checkpoint.executionID,
            currentNodeID: checkpoint.nextNode,
            attempt: checkpoint.attempt,
            steps: checkpoint.steps,
            events: checkpoint.events + [resumed],
            recoveries: checkpoint.recoveries,
            artifactStore: artifactStore,
            onCheckpoint: onCheckpoint,
            onEvent: onEvent
        )
    }

    private static func derivedDefinitionID(
        initialNode: NodeID,
        nodes: [AnyWorkflowNode<State>],
        configuration: WorkflowConfiguration
    ) -> WorkflowDefinitionID {
        let nodeSignature =
            nodes
            .map(\.id.rawValue)
            .sorted()
            .map { "\($0.count):\($0)" }
            .joined(separator: "|")
        return WorkflowDefinitionID(
            rawValue: "derived-v1:\(initialNode.rawValue):"
                + "\(configuration.maximumSteps):"
                + "\(configuration.maximumRetriesPerNode):"
                + nodeSignature
        )
    }
}

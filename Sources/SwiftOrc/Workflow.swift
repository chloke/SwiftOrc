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

        let result = try await execute(
            state: initialState,
            executionID: executionID,
            currentNodeID: initialNode,
            attempt: 1,
            steps: 0,
            events: [started],
            recoveries: [],
            executionBudget: nil,
            artifactStore: artifactStore,
            onCheckpoint: onCheckpoint,
            onEvent: onEvent
        )
        return try Self.completedRun(result)
    }

    /// Starts a workflow and yields a continuation when this invocation's
    /// execution budget is exhausted at a safe node boundary.
    public func run(
        _ initialState: State,
        budget: WorkflowExecutionBudget,
        onEvent: WorkflowEventHandler? = nil,
        onCheckpoint: WorkflowCheckpointHandler<State>? = nil,
        artifactStore: (any WorkflowArtifactStore)? = nil
    ) async throws -> WorkflowExecutionResult<State> {
        try validate(budget)

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
            executionBudget: budget,
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
        try requireNoPendingInput(checkpoint)

        let resumed = WorkflowEvent.resumed(
            executionID: checkpoint.executionID,
            node: checkpoint.nextNode,
            attempt: checkpoint.attempt,
            steps: checkpoint.steps
        )
        await onEvent?(resumed)

        let result = try await execute(
            state: checkpoint.state,
            executionID: checkpoint.executionID,
            currentNodeID: checkpoint.nextNode,
            attempt: checkpoint.attempt,
            steps: checkpoint.steps,
            events: checkpoint.events + [resumed],
            recoveries: checkpoint.recoveries,
            executionBudget: nil,
            artifactStore: artifactStore,
            inputResponse: checkpoint.inputResponse,
            onCheckpoint: onCheckpoint,
            onEvent: onEvent
        )
        return try Self.completedRun(result)
    }

    /// Continues a workflow from a checkpoint and applies a fresh execution
    /// budget to this invocation.
    public func resume(
        from checkpoint: WorkflowCheckpoint<State>,
        budget: WorkflowExecutionBudget,
        onEvent: WorkflowEventHandler? = nil,
        onCheckpoint: WorkflowCheckpointHandler<State>? = nil,
        artifactStore: (any WorkflowArtifactStore)? = nil
    ) async throws -> WorkflowExecutionResult<State> {
        try validate(checkpoint)
        try requireNoPendingInput(checkpoint)
        try validate(budget)

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
            executionBudget: budget,
            artifactStore: artifactStore,
            inputResponse: checkpoint.inputResponse,
            onCheckpoint: onCheckpoint,
            onEvent: onEvent
        )
    }

    /// Continues a workflow that suspended because a node asked for input.
    ///
    /// The answer is accepted only for the request the checkpoint is waiting
    /// on, so stale or duplicate answers are rejected. Write a typed answer
    /// into state with `update`, pass a generic one as `value`, or both; the
    /// next node finds `value` in ``WorkflowContext/inputResponse``.
    ///
    /// - Returns: `.completed` when the workflow finishes, or `.suspended` if
    ///   it asks for input again or exhausts `budget`.
    public func resume(
        from checkpoint: WorkflowCheckpoint<State>,
        answering requestID: UUID,
        with value: JSONValue? = nil,
        budget: WorkflowExecutionBudget = .unlimited,
        onEvent: WorkflowEventHandler? = nil,
        onCheckpoint: WorkflowCheckpointHandler<State>? = nil,
        artifactStore: (any WorkflowArtifactStore)? = nil
    ) async throws -> WorkflowExecutionResult<State> {
        try await resume(
            from: checkpoint,
            answering: requestID,
            with: value,
            budget: budget,
            onEvent: onEvent,
            onCheckpoint: onCheckpoint,
            artifactStore: artifactStore,
            update: { _ in }
        )
    }

    /// Continues a workflow that suspended for input, first writing the
    /// answer into state with `update`:
    ///
    /// ```swift
    /// try await workflow.resume(from: checkpoint, answering: request.id) { state in
    ///     state.confirmed = true
    /// }
    /// ```
    public func resume(
        from checkpoint: WorkflowCheckpoint<State>,
        answering requestID: UUID,
        with value: JSONValue? = nil,
        budget: WorkflowExecutionBudget = .unlimited,
        onEvent: WorkflowEventHandler? = nil,
        onCheckpoint: WorkflowCheckpointHandler<State>? = nil,
        artifactStore: (any WorkflowArtifactStore)? = nil,
        update: (inout State) async throws -> Void
    ) async throws -> WorkflowExecutionResult<State> {
        try validate(checkpoint)
        try validate(budget)
        guard let request = checkpoint.pendingInput else {
            throw WorkflowError.checkpointNotAwaitingInput
        }
        guard request.id == requestID else {
            throw WorkflowError.inputRequestMismatch(
                expected: request.id,
                actual: requestID
            )
        }
        if let expiresAt = request.expiresAt, expiresAt < Date() {
            throw WorkflowError.inputRequestExpired(request.id)
        }

        var state = checkpoint.state
        try await update(&state)

        let resumed = WorkflowEvent.resumed(
            executionID: checkpoint.executionID,
            node: checkpoint.nextNode,
            attempt: checkpoint.attempt,
            steps: checkpoint.steps
        )
        let received = WorkflowEvent.inputReceived(
            node: checkpoint.nextNode,
            requestID: request.id
        )
        await onEvent?(resumed)
        await onEvent?(received)

        return try await execute(
            state: state,
            executionID: checkpoint.executionID,
            currentNodeID: checkpoint.nextNode,
            attempt: checkpoint.attempt,
            steps: checkpoint.steps,
            events: checkpoint.events + [resumed, received],
            recoveries: checkpoint.recoveries,
            executionBudget: budget,
            artifactStore: artifactStore,
            inputResponse: WorkflowInputResponse(request: request, value: value),
            onCheckpoint: onCheckpoint,
            onEvent: onEvent
        )
    }

    private func requireNoPendingInput(
        _ checkpoint: WorkflowCheckpoint<State>
    ) throws {
        if let request = checkpoint.pendingInput {
            throw WorkflowError.checkpointAwaitingInput(request.id)
        }
    }

    /// Unbudgeted runs can only suspend when a node asks for input.
    private static func completedRun(
        _ result: WorkflowExecutionResult<State>
    ) throws -> WorkflowRun<State> {
        switch result {
        case let .completed(run):
            return run
        case let .suspended(continuation):
            throw WorkflowInputRequired(continuation: continuation)
        }
    }

    private func validate(_ budget: WorkflowExecutionBudget) throws {
        if let maximum = budget.maximumNodeExecutions,
            maximum <= 0
        {
            throw
                WorkflowExecutionBudgetError
                .invalidMaximumNodeExecutions(maximum)
        }
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

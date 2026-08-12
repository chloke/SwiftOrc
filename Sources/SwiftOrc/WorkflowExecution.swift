import Foundation

extension Workflow {
    func execute(
        state initialState: State,
        executionID: UUID,
        currentNodeID initialNodeID: NodeID,
        attempt initialAttempt: Int,
        steps initialSteps: Int,
        events initialEvents: [WorkflowEvent],
        recoveries initialRecoveries: [WorkflowRecovery],
        executionBudget: WorkflowExecutionBudget?,
        artifactStore: (any WorkflowArtifactStore)?,
        onCheckpoint: WorkflowCheckpointHandler<State>?,
        onEvent: WorkflowEventHandler?
    ) async throws -> WorkflowExecutionResult<State> {
        var cursor = WorkflowExecutionCursor(
            state: initialState,
            currentNodeID: initialNodeID,
            attempt: initialAttempt,
            steps: initialSteps,
            events: initialEvents,
            recoveries: initialRecoveries,
            shouldCreateCheckpoint: true
        )
        var invocationNodeExecutions = 0

        while true {
            if let executionBudget {
                try await checkCancellation(
                    cursor: &cursor,
                    onEvent: onEvent
                )
                try await requireRemainingWorkflowSteps(
                    cursor: &cursor,
                    executionID: executionID,
                    onEvent: onEvent
                )

                if let reason = suspensionReason(
                    for: executionBudget,
                    nodeExecutions: invocationNodeExecutions
                ) {
                    let continuation = try await suspend(
                        cursor: &cursor,
                        executionID: executionID,
                        reason: reason,
                        nodeExecutions: invocationNodeExecutions,
                        onCheckpoint: onCheckpoint,
                        onEvent: onEvent
                    )
                    return .suspended(continuation)
                }
            }

            if cursor.shouldCreateCheckpoint {
                try await createCheckpointIfNeeded(
                    cursor: &cursor,
                    executionID: executionID,
                    onCheckpoint: onCheckpoint,
                    onEvent: onEvent
                )
            }

            try await checkCancellation(cursor: &cursor, onEvent: onEvent)
            try await requireRemainingWorkflowSteps(
                cursor: &cursor,
                executionID: executionID,
                onEvent: onEvent
            )

            guard let node = nodes[cursor.currentNodeID] else {
                let error = WorkflowError.transitionTargetNotFound(
                    from: cursor.currentNodeID,
                    target: cursor.currentNodeID
                )
                throw await cursor.terminalError(
                    capturing: error,
                    executionID: executionID,
                    node: cursor.currentNodeID,
                    onEvent: onEvent
                )
            }

            cursor.steps += 1
            invocationNodeExecutions += 1
            let context = WorkflowContext(
                executionID: executionID,
                nodeID: cursor.currentNodeID,
                attempt: cursor.attempt,
                step: cursor.steps,
                artifactStore: artifactStore
            )
            await cursor.record(
                .nodeStarted(
                    node: cursor.currentNodeID,
                    attempt: cursor.attempt,
                    step: cursor.steps
                ),
                onEvent: onEvent
            )

            let result: NodeResult<State>
            do {
                result = try await node.run(
                    state: cursor.state,
                    context: context
                )
            } catch is CancellationError {
                await cursor.record(
                    .cancelled(node: cursor.currentNodeID),
                    onEvent: onEvent
                )
                throw CancellationError()
            } catch {
                throw await cursor.terminalError(
                    capturing: error,
                    executionID: executionID,
                    node: cursor.currentNodeID,
                    includeNodeFailure: true,
                    onEvent: onEvent
                )
            }

            let resolved = resolveNodeResult(result)
            for annotation in resolved.annotations {
                await cursor.record(
                    .annotation(
                        node: cursor.currentNodeID,
                        value: annotation
                    ),
                    onEvent: onEvent
                )
            }

            if let run = try await process(
                resolved.transition,
                cursor: &cursor,
                executionID: executionID,
                onEvent: onEvent
            ) {
                return .completed(run)
            }
        }
    }

    private func checkCancellation(
        cursor: inout WorkflowExecutionCursor<State>,
        onEvent: WorkflowEventHandler?
    ) async throws {
        do {
            try Task.checkCancellation()
        } catch {
            await cursor.record(
                .cancelled(node: cursor.currentNodeID),
                onEvent: onEvent
            )
            throw CancellationError()
        }
    }

    private func requireRemainingWorkflowSteps(
        cursor: inout WorkflowExecutionCursor<State>,
        executionID: UUID,
        onEvent: WorkflowEventHandler?
    ) async throws {
        guard cursor.steps < configuration.maximumSteps else {
            let error = WorkflowError.stepLimitExceeded(
                limit: configuration.maximumSteps
            )
            throw await cursor.terminalError(
                capturing: error,
                executionID: executionID,
                node: cursor.currentNodeID,
                onEvent: onEvent
            )
        }
    }

    private func suspensionReason(
        for budget: WorkflowExecutionBudget,
        nodeExecutions: Int
    ) -> WorkflowSuspensionReason? {
        if let maximum = budget.maximumNodeExecutions,
            nodeExecutions >= maximum
        {
            return .maximumNodeExecutionsReached(limit: maximum)
        }
        if let deadline = budget.deadline,
            ContinuousClock().now >= deadline
        {
            return .deadlineReached
        }
        return nil
    }

    private func suspend(
        cursor: inout WorkflowExecutionCursor<State>,
        executionID: UUID,
        reason: WorkflowSuspensionReason,
        nodeExecutions: Int,
        onCheckpoint: WorkflowCheckpointHandler<State>?,
        onEvent: WorkflowEventHandler?
    ) async throws -> WorkflowContinuation<State> {
        await cursor.record(
            .checkpointCreated(
                executionID: executionID,
                nextNode: cursor.currentNodeID,
                attempt: cursor.attempt,
                steps: cursor.steps
            ),
            onEvent: onEvent
        )

        let checkpoint = WorkflowCheckpoint(
            definitionID: definitionID,
            executionID: executionID,
            state: cursor.state,
            nextNode: cursor.currentNodeID,
            attempt: cursor.attempt,
            steps: cursor.steps,
            events: cursor.events,
            recoveries: cursor.recoveries
        )

        if let onCheckpoint {
            do {
                try await onCheckpoint(checkpoint)
            } catch is CancellationError {
                await cursor.record(
                    .cancelled(node: cursor.currentNodeID),
                    onEvent: onEvent
                )
                throw CancellationError()
            } catch {
                throw await cursor.terminalError(
                    capturing: error,
                    executionID: executionID,
                    node: cursor.currentNodeID,
                    onEvent: onEvent
                )
            }
        }

        return WorkflowContinuation(
            checkpoint: checkpoint,
            reason: reason,
            nodeExecutions: nodeExecutions
        )
    }

    func validate(_ checkpoint: WorkflowCheckpoint<State>) throws {
        guard
            checkpoint.formatVersion
                == WorkflowCheckpoint<State>.currentFormatVersion
        else {
            throw WorkflowError.unsupportedCheckpointVersion(
                checkpoint.formatVersion
            )
        }
        guard checkpoint.definitionID == definitionID else {
            throw WorkflowError.checkpointDefinitionMismatch(
                expected: definitionID,
                actual: checkpoint.definitionID
            )
        }
        guard nodes[checkpoint.nextNode] != nil else {
            throw WorkflowError.checkpointNodeNotFound(checkpoint.nextNode)
        }
        guard checkpoint.attempt > 0 else {
            throw WorkflowError.invalidCheckpointAttempt(checkpoint.attempt)
        }
        guard checkpoint.steps >= 0 else {
            throw WorkflowError.invalidCheckpointSteps(checkpoint.steps)
        }
    }

    private func createCheckpointIfNeeded(
        cursor: inout WorkflowExecutionCursor<State>,
        executionID: UUID,
        onCheckpoint: WorkflowCheckpointHandler<State>?,
        onEvent: WorkflowEventHandler?
    ) async throws {
        if let onCheckpoint {
            await cursor.record(
                .checkpointCreated(
                    executionID: executionID,
                    nextNode: cursor.currentNodeID,
                    attempt: cursor.attempt,
                    steps: cursor.steps
                ),
                onEvent: onEvent
            )

            let checkpoint = WorkflowCheckpoint(
                definitionID: definitionID,
                executionID: executionID,
                state: cursor.state,
                nextNode: cursor.currentNodeID,
                attempt: cursor.attempt,
                steps: cursor.steps,
                events: cursor.events,
                recoveries: cursor.recoveries
            )

            do {
                try await onCheckpoint(checkpoint)
            } catch is CancellationError {
                await cursor.record(
                    .cancelled(node: cursor.currentNodeID),
                    onEvent: onEvent
                )
                throw CancellationError()
            } catch {
                throw await cursor.terminalError(
                    capturing: error,
                    executionID: executionID,
                    node: cursor.currentNodeID,
                    onEvent: onEvent
                )
            }
        }
        cursor.shouldCreateCheckpoint = false
    }

    private func process(
        _ transition: ResolvedWorkflowTransition<State>,
        cursor: inout WorkflowExecutionCursor<State>,
        executionID: UUID,
        onEvent: WorkflowEventHandler?
    ) async throws -> WorkflowRun<State>? {
        let source = cursor.currentNodeID

        switch transition {
        case let .next(state, target):
            await cursor.record(
                .nodeCompleted(node: source, transition: .next(target)),
                onEvent: onEvent
            )
            try await cursor.requireTarget(
                target,
                from: source,
                nodes: nodes,
                executionID: executionID,
                onEvent: onEvent
            )
            cursor.advance(to: target, state: state)

        case let .route(state, target, name):
            await cursor.record(
                .nodeCompleted(node: source, transition: .next(target)),
                onEvent: onEvent
            )
            await cursor.record(
                .branchSelected(node: source, route: name, target: target),
                onEvent: onEvent
            )
            try await cursor.requireTarget(
                target,
                from: source,
                nodes: nodes,
                executionID: executionID,
                onEvent: onEvent
            )
            cursor.advance(to: target, state: state)

        case let .parallel(state, continuation, branches):
            await cursor.record(
                .parallelBranchesCompleted(node: source, branches: branches),
                onEvent: onEvent
            )
            switch continuation {
            case let .next(target):
                await cursor.record(
                    .nodeCompleted(node: source, transition: .next(target)),
                    onEvent: onEvent
                )
                try await cursor.requireTarget(
                    target,
                    from: source,
                    nodes: nodes,
                    executionID: executionID,
                    onEvent: onEvent
                )
                cursor.advance(to: target, state: state)
            case .finish:
                await cursor.record(
                    .nodeCompleted(node: source, transition: .finish),
                    onEvent: onEvent
                )
                return await cursor.finishedRun(
                    state: state,
                    executionID: executionID,
                    finalNode: source,
                    onEvent: onEvent
                )
            }

        case let .retry(state, reason):
            await cursor.record(
                .nodeCompleted(node: source, transition: .retry),
                onEvent: onEvent
            )
            let retriesAlreadyPerformed = cursor.attempt - 1
            guard
                retriesAlreadyPerformed
                    < configuration.maximumRetriesPerNode
            else {
                let error = WorkflowError.retryLimitExceeded(
                    node: source,
                    limit: configuration.maximumRetriesPerNode
                )
                throw await cursor.terminalError(
                    capturing: error,
                    executionID: executionID,
                    node: source,
                    onEvent: onEvent
                )
            }
            cursor.state = state
            cursor.attempt += 1
            await cursor.record(
                .retryScheduled(
                    node: source,
                    nextAttempt: cursor.attempt,
                    reason: reason
                ),
                onEvent: onEvent
            )
            cursor.shouldCreateCheckpoint = true

        case let .fallback(state, target, failure):
            await cursor.record(
                .nodeCompleted(node: source, transition: .fallback(target)),
                onEvent: onEvent
            )
            try await cursor.requireTarget(
                target,
                from: source,
                nodes: nodes,
                executionID: executionID,
                onEvent: onEvent
            )
            await cursor.record(
                .fallbackSelected(
                    node: source,
                    target: target,
                    failure: failure
                ),
                onEvent: onEvent
            )
            cursor.recoveries.append(
                WorkflowRecovery(
                    node: source,
                    target: target,
                    failure: failure
                )
            )
            cursor.advance(to: target, state: state)

        case let .finish(state):
            await cursor.record(
                .nodeCompleted(node: source, transition: .finish),
                onEvent: onEvent
            )
            return await cursor.finishedRun(
                state: state,
                executionID: executionID,
                finalNode: source,
                onEvent: onEvent
            )
        }

        return nil
    }
}

private struct WorkflowExecutionCursor<State: Sendable> {
    var state: State
    var currentNodeID: NodeID
    var attempt: Int
    var steps: Int
    var events: [WorkflowEvent]
    var recoveries: [WorkflowRecovery]
    var shouldCreateCheckpoint: Bool

    mutating func record(
        _ event: WorkflowEvent,
        onEvent: WorkflowEventHandler?
    ) async {
        events.append(event)
        await onEvent?(event)
    }

    mutating func terminalError(
        capturing error: any Error,
        executionID: UUID,
        node: NodeID,
        includeNodeFailure: Bool = false,
        onEvent: WorkflowEventHandler?
    ) async -> WorkflowExecutionError {
        let failure = WorkflowFailure(error: error)
        if includeNodeFailure {
            await record(
                .nodeFailed(node: node, failure: failure),
                onEvent: onEvent
            )
        }
        await record(
            .workflowFailed(
                executionID: executionID,
                node: node,
                failure: failure,
                steps: steps
            ),
            onEvent: onEvent
        )
        return WorkflowExecutionError(
            capturing: error,
            executionID: executionID,
            node: node,
            steps: steps,
            events: events
        )
    }

    mutating func requireTarget(
        _ target: NodeID,
        from source: NodeID,
        nodes: [NodeID: AnyWorkflowNode<State>],
        executionID: UUID,
        onEvent: WorkflowEventHandler?
    ) async throws {
        guard nodes[target] != nil else {
            let error = WorkflowError.transitionTargetNotFound(
                from: source,
                target: target
            )
            throw await terminalError(
                capturing: error,
                executionID: executionID,
                node: source,
                onEvent: onEvent
            )
        }
    }

    mutating func advance(to target: NodeID, state: State) {
        self.state = state
        currentNodeID = target
        attempt = 1
        shouldCreateCheckpoint = true
    }

    mutating func finishedRun(
        state: State,
        executionID: UUID,
        finalNode: NodeID,
        onEvent: WorkflowEventHandler?
    ) async -> WorkflowRun<State> {
        await record(
            .finished(
                executionID: executionID,
                finalNode: finalNode,
                steps: steps
            ),
            onEvent: onEvent
        )
        return WorkflowRun(
            state: state,
            executionID: executionID,
            finalNode: finalNode,
            steps: steps,
            events: events,
            outcome: recoveries.isEmpty
                ? .completed
                : .recovered(recoveries)
        )
    }
}

private enum ResolvedWorkflowTransition<State: Sendable> {
    case next(State, NodeID)
    case route(State, NodeID, name: String)
    case parallel(State, ParallelContinuation, branches: [String])
    case retry(State, reason: WorkflowFailure?)
    case fallback(State, NodeID, failure: WorkflowFailure)
    case finish(State)
}

private struct ResolvedWorkflowNodeResult<State: Sendable> {
    let transition: ResolvedWorkflowTransition<State>
    let annotations: [WorkflowAnnotation]
}

private func resolveNodeResult<State: Sendable>(
    _ result: NodeResult<State>
) -> ResolvedWorkflowNodeResult<State> {
    var annotations: [WorkflowAnnotation] = []
    let transition = resolveTransition(result, annotations: &annotations)
    return ResolvedWorkflowNodeResult(
        transition: transition,
        annotations: annotations
    )
}

private func resolveTransition<State: Sendable>(
    _ result: NodeResult<State>,
    annotations: inout [WorkflowAnnotation]
) -> ResolvedWorkflowTransition<State> {
    switch result {
    case let .annotated(innerResult, annotation):
        annotations.append(annotation)
        return resolveTransition(innerResult, annotations: &annotations)
    case let .next(state, target):
        return .next(state, target)
    case let .route(state, target, name):
        return .route(state, target, name: name)
    case let .parallel(state, continuation, branches):
        return .parallel(state, continuation, branches: branches)
    case let .retry(state, reason):
        return .retry(state, reason: reason)
    case let .fallback(state, target, failure):
        return .fallback(state, target, failure: failure)
    case let .finish(state):
        return .finish(state)
    }
}

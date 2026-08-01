/// The result of checking a workflow state against an application rule.
public enum ValidationResult: Sendable, Equatable {
    case valid
    case invalid(reason: String)
}

/// A reusable asynchronous validation rule for workflow state.
public struct WorkflowValidator<State: Sendable>: Sendable {
    private let operation:
        @Sendable (
            State,
            WorkflowContext
        ) async throws -> ValidationResult

    public init(
        _ validate:
            @escaping @Sendable (
                State,
                WorkflowContext
            ) async throws -> ValidationResult
    ) {
        operation = validate
    }

    public func validate(
        _ state: State,
        context: WorkflowContext
    ) async throws -> ValidationResult {
        try await operation(state, context)
    }
}

/// A reusable policy for converting thrown node errors into workflow retries.
///
/// `maximumAttempts` includes the first execution. The workflow's global
/// `maximumRetriesPerNode` remains a hard upper bound.
public struct WorkflowNodeRetryPolicy: Sendable {
    public var maximumAttempts: Int
    public var delay: Duration

    private let predicate: @Sendable (any Error) -> Bool

    public init(
        maximumAttempts: Int = 3,
        delay: Duration = .zero,
        shouldRetry: @escaping @Sendable (any Error) -> Bool = { _ in true }
    ) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.delay = max(.zero, delay)
        predicate = shouldRetry
    }

    public func shouldRetry(_ error: any Error) -> Bool {
        predicate(error)
    }
}

/// The action taken when a node produces state that fails validation.
public enum ValidationFailureBehavior: Sendable, Equatable {
    /// Retry the same node with the state it just produced.
    case retry

    /// Route the invalid state to another node, such as a repair step.
    case route(to: NodeID)

    /// Stop the workflow with a validation error.
    case fail
}

public extension AnyWorkflowNode {
    /// Converts eligible thrown errors into observable workflow retries.
    ///
    /// The original input state is supplied to the next attempt. Set the
    /// workflow's `maximumRetriesPerNode` to at least `maximumAttempts - 1` if
    /// this policy should control the full retry budget.
    func retrying(
        _ policy: WorkflowNodeRetryPolicy = WorkflowNodeRetryPolicy()
    ) -> AnyWorkflowNode<State> {
        let base = self

        return AnyWorkflowNode(
            id: id,
            declaredDestinations: declaredDestinations
        ) { state, context in
            do {
                return try await base.run(state: state, context: context)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard policy.maximumAttempts > 1,
                    context.attempt < policy.maximumAttempts,
                    policy.shouldRetry(error)
                else {
                    throw error
                }

                if policy.delay > .zero {
                    try await Task.sleep(for: policy.delay)
                }
                return .retry(state, reason: WorkflowFailure(error: error))
            }
        }
    }

    /// Validates successful output before allowing a node to transition.
    ///
    /// Explicit retries and fallbacks returned by the wrapped node bypass
    /// validation because they are not successful output states.
    func validated(
        by validator: WorkflowValidator<State>,
        onFailure behavior: ValidationFailureBehavior = .retry
    ) -> AnyWorkflowNode<State> {
        let base = self
        let validationDestinations: Set<NodeID>
        if case let .route(target) = behavior {
            validationDestinations = declaredDestinations.union([target])
        } else {
            validationDestinations = declaredDestinations
        }

        return AnyWorkflowNode(
            id: id,
            declaredDestinations: validationDestinations
        ) { state, context in
            let result = try await base.run(state: state, context: context)
            return try await validatedNodeResult(
                result,
                nodeID: base.id,
                context: context,
                validator: validator,
                behavior: behavior
            )
        }
    }

    /// Stops a node and throws a timeout error if it does not finish in time.
    ///
    /// The wrapped operation receives cooperative task cancellation when the
    /// timeout wins the race. Swift structured concurrency still waits for the
    /// child task to finish, so work that ignores cancellation can delay the
    /// thrown timeout. Use transport-level deadlines for non-cooperative I/O.
    func timeout(after duration: Duration) -> AnyWorkflowNode<State> {
        let base = self

        return AnyWorkflowNode(
            id: id,
            declaredDestinations: declaredDestinations
        ) { state, context in
            try await withThrowingTaskGroup(of: NodeResult<State>.self) { group in
                group.addTask {
                    try await base.run(state: state, context: context)
                }
                group.addTask {
                    try await Task.sleep(for: duration)
                    try Task.checkCancellation()
                    throw WorkflowError.nodeTimedOut(
                        node: base.id,
                        timeout: duration
                    )
                }

                defer { group.cancelAll() }
                guard let firstResult = try await group.next() else {
                    throw CancellationError()
                }
                return firstResult
            }
        }
    }

    /// Routes failures from this node to another node while preserving the
    /// failure details in the workflow trace.
    func recover(to fallbackNode: NodeID) -> AnyWorkflowNode<State> {
        let base = self

        return AnyWorkflowNode(
            id: id,
            declaredDestinations: declaredDestinations.union([fallbackNode])
        ) { state, context in
            do {
                return try await base.run(state: state, context: context)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .fallback(
                    state,
                    fallbackNode,
                    failure: WorkflowFailure(error: error)
                )
            }
        }
    }
}

private func validatedNodeResult<State: Sendable>(
    _ result: NodeResult<State>,
    nodeID: NodeID,
    context: WorkflowContext,
    validator: WorkflowValidator<State>,
    behavior: ValidationFailureBehavior
) async throws -> NodeResult<State> {
    switch result {
    case let .annotated(innerResult, annotation):
        return .annotated(
            try await validatedNodeResult(
                innerResult,
                nodeID: nodeID,
                context: context,
                validator: validator,
                behavior: behavior
            ),
            annotation
        )
    case let .next(updatedState, target):
        return try await validatedResult(
            state: updatedState,
            originalResult: .next(updatedState, target),
            nodeID: nodeID,
            context: context,
            validator: validator,
            behavior: behavior
        )
    case let .route(updatedState, target, name):
        return try await validatedResult(
            state: updatedState,
            originalResult: .route(updatedState, target, name: name),
            nodeID: nodeID,
            context: context,
            validator: validator,
            behavior: behavior
        )
    case let .parallel(updatedState, continuation, branches):
        return try await validatedResult(
            state: updatedState,
            originalResult: .parallel(
                updatedState,
                continuation: continuation,
                branches: branches
            ),
            nodeID: nodeID,
            context: context,
            validator: validator,
            behavior: behavior
        )
    case let .finish(updatedState):
        return try await validatedResult(
            state: updatedState,
            originalResult: .finish(updatedState),
            nodeID: nodeID,
            context: context,
            validator: validator,
            behavior: behavior
        )
    case .retry, .fallback:
        return result
    }
}

private func validatedResult<State: Sendable>(
    state: State,
    originalResult: NodeResult<State>,
    nodeID: NodeID,
    context: WorkflowContext,
    validator: WorkflowValidator<State>,
    behavior: ValidationFailureBehavior
) async throws -> NodeResult<State> {
    switch try await validator.validate(state, context: context) {
    case .valid:
        return originalResult
    case let .invalid(reason):
        let error = WorkflowError.validationFailed(
            node: nodeID,
            reason: reason
        )
        let failure = WorkflowFailure(error: error)

        switch behavior {
        case .retry:
            return .retry(state, reason: failure)
        case let .route(target):
            return .fallback(state, target, failure: failure)
        case .fail:
            throw error
        }
    }
}

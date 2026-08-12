import Foundation
import Testing

@testable import SwiftOrc

private struct TestState: Sendable, Equatable, Codable {
    var value = 0
    var route = ""
}

private actor EventRecorder {
    private(set) var events: [WorkflowEvent] = []

    func record(_ event: WorkflowEvent) {
        events.append(event)
    }
}

private actor StringRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private actor CheckpointRecorder<State: Sendable> {
    private(set) var checkpoints: [WorkflowCheckpoint<State>] = []

    func record(_ checkpoint: WorkflowCheckpoint<State>) {
        checkpoints.append(checkpoint)
    }
}

private actor RoutingEventRecorder {
    private(set) var events: [LanguageModelRoutingEvent] = []

    func record(_ event: LanguageModelRoutingEvent) {
        events.append(event)
    }
}

@Test
func runsNodesSequentially() async throws {
    let increment = AnyWorkflowNode<TestState>(id: "increment") { state, _ in
        var state = state
        state.value += 1
        return .next(state, "finish")
    }
    let finish = AnyWorkflowNode<TestState>(id: "finish") { state, _ in
        var state = state
        state.value *= 2
        return .finish(state)
    }
    let workflow = try Workflow(
        initialNode: "increment",
        nodes: [increment, finish]
    )

    let run = try await workflow.run(TestState())

    #expect(run.state.value == 2)
    #expect(run.finalNode == "finish")
    #expect(run.steps == 2)
    #expect(run.events.count == 6)
    #expect(run.outcome == .completed)
}

@Test
func selectsNamedBranchRoutesAndDefault() async throws {
    let branch = BranchNode<TestState>(
        id: "branch",
        routes: [
            BranchRoute("left-route", to: "left") { state, _ in
                state.route == "left"
            },
            BranchRoute("right-route", to: "right") { state, _ in
                state.route == "right"
            },
        ],
        defaultTarget: "other",
        defaultRouteName: "other-route"
    )
    let left = AnyWorkflowNode<TestState>(id: "left") { state, _ in
        var state = state
        state.value = 10
        return .finish(state)
    }
    let right = AnyWorkflowNode<TestState>(id: "right") { state, _ in
        var state = state
        state.value = 20
        return .finish(state)
    }
    let other = AnyWorkflowNode<TestState>(id: "other") { state, _ in
        var state = state
        state.value = 30
        return .finish(state)
    }
    let workflow = try Workflow(
        initialNode: "branch",
        nodes: [AnyWorkflowNode(branch), left, right, other]
    )

    let expectations = [
        (input: "left", value: 10, route: "left-route", target: NodeID(rawValue: "left")),
        (input: "right", value: 20, route: "right-route", target: NodeID(rawValue: "right")),
        (input: "unknown", value: 30, route: "other-route", target: NodeID(rawValue: "other")),
    ]

    for expectation in expectations {
        let run = try await workflow.run(TestState(route: expectation.input))

        #expect(run.state.value == expectation.value)
        #expect(run.finalNode == expectation.target)
        #expect(
            run.events.contains(
                .branchSelected(
                    node: "branch",
                    route: expectation.route,
                    target: expectation.target
                )
            )
        )
    }
}

@Test
func selectsTheFirstMatchingBranchRoute() async throws {
    let branch = BranchNode<TestState>(
        id: "branch",
        routes: [
            BranchRoute("first", to: "first") { _, _ in true },
            BranchRoute("second", to: "second") { _, _ in true },
        ],
        defaultTarget: "second"
    )
    let first = AnyWorkflowNode<TestState>(id: "first") { state, _ in
        .finish(state)
    }
    let second = AnyWorkflowNode<TestState>(id: "second") { state, _ in
        .finish(state)
    }
    let workflow = try Workflow<TestState>(initialNode: "branch") {
        branch
        first
        second
    }

    let run = try await workflow.run(TestState())

    #expect(run.finalNode == "first")
    #expect(
        run.events.contains(
            .branchSelected(node: "branch", route: "first", target: "first")
        )
    )
}

@Test
func rejectsMissingDeclaredBranchDestinations() throws {
    let branch = BranchNode<TestState>(
        id: "branch",
        routes: [
            BranchRoute("unreachable", to: "missing") { _, _ in false }
        ],
        defaultTarget: "finish"
    )
    let finish = AnyWorkflowNode<TestState>(id: "finish") { state, _ in
        .finish(state)
    }

    do {
        _ = try Workflow<TestState>(initialNode: "branch") {
            branch
            finish
        }
        Issue.record("Expected the workflow to reject a declared missing target")
    } catch let error as WorkflowError {
        #expect(
            error
                == .declaredDestinationNotFound(
                    from: "branch",
                    target: "missing"
                )
        )
    }
}

@Test
func retriesWithinConfiguredLimit() async throws {
    let node = AnyWorkflowNode<TestState>(id: "sometimes") { state, context in
        if context.attempt == 1 {
            return .retry(state)
        }
        var state = state
        state.value = context.attempt
        return .finish(state)
    }
    let workflow = try Workflow(initialNode: "sometimes", nodes: [node])

    let run = try await workflow.run(TestState())

    #expect(run.state.value == 2)
    #expect(run.steps == 2)
}

@Test
func stopsAtRetryLimit() async throws {
    let node = AnyWorkflowNode<TestState>(id: "always-retry") { state, _ in
        .retry(state)
    }
    let workflow = try Workflow(
        initialNode: "always-retry",
        nodes: [node],
        configuration: WorkflowConfiguration(
            maximumSteps: 10,
            maximumRetriesPerNode: 1
        )
    )

    do {
        _ = try await workflow.run(TestState())
        Issue.record("Expected the workflow to exceed its retry limit")
    } catch let error as WorkflowExecutionError {
        #expect(
            error.workflowError
                == .retryLimitExceeded(node: "always-retry", limit: 1)
        )
        #expect(error.node == "always-retry")
        #expect(error.events.last != nil)
    }
}

@Test
func stopsInfiniteGraphsAtStepLimit() async throws {
    let loop = AnyWorkflowNode<TestState>(id: "loop") { state, _ in
        .next(state, "loop")
    }
    let workflow = try Workflow(
        initialNode: "loop",
        nodes: [loop],
        configuration: WorkflowConfiguration(
            maximumSteps: 2,
            maximumRetriesPerNode: 0
        )
    )

    do {
        _ = try await workflow.run(TestState())
        Issue.record("Expected the workflow to exceed its step limit")
    } catch let error as WorkflowExecutionError {
        #expect(error.workflowError == .stepLimitExceeded(limit: 2))
        #expect(error.steps == 2)
    }
}

@Test
func budgetedExecutionSuspendsAndResumesWithoutRepeatingNodes() async throws {
    let first = AnyWorkflowNode<TestState>(id: "first") { state, _ in
        var state = state
        state.value += 1
        return .next(state, "second")
    }
    let second = AnyWorkflowNode<TestState>(id: "second") { state, _ in
        var state = state
        state.value += 10
        return .next(state, "third")
    }
    let third = AnyWorkflowNode<TestState>(id: "third") { state, _ in
        var state = state
        state.value += 100
        return .finish(state)
    }
    let workflow = try Workflow<TestState>(
        definitionID: "budgeted-resume-v1",
        initialNode: "first"
    ) {
        first
        second
        third
    }
    let budget = WorkflowExecutionBudget(maximumNodeExecutions: 1)

    let firstResult = try await workflow.run(TestState(), budget: budget)
    guard case let .suspended(firstContinuation) = firstResult else {
        Issue.record("Expected the first invocation to suspend")
        return
    }
    #expect(firstContinuation.nodeExecutions == 1)
    #expect(
        firstContinuation.reason
            == .maximumNodeExecutionsReached(limit: 1)
    )
    #expect(firstContinuation.checkpoint.state.value == 1)
    #expect(firstContinuation.checkpoint.nextNode == "second")
    #expect(firstContinuation.checkpoint.steps == 1)

    let encodedContinuation = try JSONEncoder().encode(firstContinuation)
    let decodedContinuation = try JSONDecoder().decode(
        WorkflowContinuation<TestState>.self,
        from: encodedContinuation
    )
    #expect(decodedContinuation.reason == firstContinuation.reason)
    #expect(decodedContinuation.nodeExecutions == 1)
    #expect(decodedContinuation.checkpoint.state.value == 1)
    #expect(decodedContinuation.checkpoint.nextNode == "second")

    let secondResult = try await workflow.resume(
        from: firstContinuation.checkpoint,
        budget: budget
    )
    guard case let .suspended(secondContinuation) = secondResult else {
        Issue.record("Expected the second invocation to suspend")
        return
    }
    #expect(secondContinuation.nodeExecutions == 1)
    #expect(secondContinuation.checkpoint.state.value == 11)
    #expect(secondContinuation.checkpoint.nextNode == "third")
    #expect(secondContinuation.checkpoint.steps == 2)
    #expect(
        secondContinuation.checkpoint.executionID
            == firstContinuation.checkpoint.executionID
    )

    let finalResult = try await workflow.resume(
        from: secondContinuation.checkpoint,
        budget: budget
    )
    guard case let .completed(run) = finalResult else {
        Issue.record("Expected the final invocation to complete")
        return
    }
    #expect(run.state.value == 111)
    #expect(run.steps == 3)
    #expect(run.executionID == firstContinuation.checkpoint.executionID)

    let starts = run.events.compactMap { event -> NodeID? in
        guard case let .nodeStarted(node, _, _) = event else { return nil }
        return node
    }
    #expect(starts == ["first", "second", "third"])
}

@Test
func budgetSuspendsWithCheckpointedRetryAttempt() async throws {
    let retry = AnyWorkflowNode<TestState>(id: "retry") { state, context in
        if context.attempt == 1 {
            return .retry(state)
        }
        var state = state
        state.value = context.attempt
        return .finish(state)
    }
    let workflow = try Workflow<TestState>(
        definitionID: "budgeted-retry-v1",
        initialNode: "retry"
    ) {
        retry
    }
    let budget = WorkflowExecutionBudget(maximumNodeExecutions: 1)

    let firstResult = try await workflow.run(TestState(), budget: budget)
    guard case let .suspended(continuation) = firstResult else {
        Issue.record("Expected the retry to consume the invocation budget")
        return
    }
    #expect(continuation.checkpoint.nextNode == "retry")
    #expect(continuation.checkpoint.attempt == 2)
    #expect(continuation.checkpoint.steps == 1)

    let resumed = try await workflow.resume(
        from: continuation.checkpoint,
        budget: budget
    )
    guard case let .completed(run) = resumed else {
        Issue.record("Expected the checkpointed retry to complete")
        return
    }
    #expect(run.state.value == 2)
    #expect(run.steps == 2)
}

@Test
func elapsedDeadlineSuspendsBeforeStartingANode() async throws {
    let calls = StringRecorder()
    let node = AnyWorkflowNode<TestState>(id: "node") { state, _ in
        await calls.append("node")
        return .finish(state)
    }
    let workflow = try Workflow<TestState>(
        definitionID: "deadline-v1",
        initialNode: "node"
    ) {
        node
    }
    let recorder = CheckpointRecorder<TestState>()
    let budget = WorkflowExecutionBudget(deadline: ContinuousClock().now)

    let result = try await workflow.run(
        TestState(),
        budget: budget,
        onCheckpoint: { checkpoint in
            await recorder.record(checkpoint)
        }
    )

    guard case let .suspended(continuation) = result else {
        Issue.record("Expected the elapsed deadline to suspend")
        return
    }
    #expect(continuation.reason == .deadlineReached)
    #expect(continuation.nodeExecutions == 0)
    #expect(continuation.checkpoint.steps == 0)
    #expect(continuation.checkpoint.nextNode == "node")
    #expect(await calls.values.isEmpty)
    #expect(await recorder.checkpoints.count == 1)
    let recordedCheckpoint = try #require(await recorder.checkpoints.first)
    #expect(recordedCheckpoint.executionID == continuation.checkpoint.executionID)
    #expect(recordedCheckpoint.nextNode == continuation.checkpoint.nextNode)
    #expect(recordedCheckpoint.steps == continuation.checkpoint.steps)
}

@Test
func rejectsNonPositiveInvocationNodeBudget() async throws {
    let node = AnyWorkflowNode<TestState>(id: "node") { state, _ in
        .finish(state)
    }
    let workflow = try Workflow<TestState>(initialNode: "node") {
        node
    }

    do {
        _ = try await workflow.run(
            TestState(),
            budget: WorkflowExecutionBudget(maximumNodeExecutions: 0)
        )
        Issue.record("Expected a non-positive node budget to be rejected")
    } catch let error as WorkflowExecutionBudgetError {
        #expect(error == .invalidMaximumNodeExecutions(0))
    }
}

@Test
func unlimitedInvocationBudgetCompletesNormally() async throws {
    let node = AnyWorkflowNode<TestState>(id: "node") { state, _ in
        var state = state
        state.value = 42
        return .finish(state)
    }
    let workflow = try Workflow<TestState>(initialNode: "node") {
        node
    }

    let result = try await workflow.run(
        TestState(),
        budget: .unlimited
    )

    guard case let .completed(run) = result else {
        Issue.record("Expected the unlimited budget to complete")
        return
    }
    #expect(run.state.value == 42)
    #expect(run.steps == 1)
}

@Test
func rejectsUnknownTransitionTargets() async throws {
    let node = AnyWorkflowNode<TestState>(id: "start") { state, _ in
        .next(state, "missing")
    }
    let workflow = try Workflow(initialNode: "start", nodes: [node])

    do {
        _ = try await workflow.run(TestState())
        Issue.record("Expected the workflow to reject an unknown target")
    } catch let error as WorkflowExecutionError {
        #expect(
            error.workflowError
                == .transitionTargetNotFound(
                    from: "start",
                    target: "missing"
                )
        )
    }
}

@Test
func rejectsDuplicateNodeIdentifiers() throws {
    let first = AnyWorkflowNode<TestState>(id: "duplicate") { state, _ in
        .finish(state)
    }
    let second = AnyWorkflowNode<TestState>(id: "duplicate") { state, _ in
        .finish(state)
    }

    do {
        _ = try Workflow(initialNode: "duplicate", nodes: [first, second])
        Issue.record("Expected duplicate identifiers to be rejected")
    } catch let error as WorkflowError {
        #expect(error == .duplicateNodeID("duplicate"))
    }
}

@Test
func respectsTaskCancellation() async throws {
    let node = AnyWorkflowNode<TestState>(id: "work") { state, _ in
        try await Task.sleep(for: .seconds(10))
        return .finish(state)
    }
    let workflow = try Workflow(initialNode: "work", nodes: [node])
    let task = Task {
        try await workflow.run(TestState())
    }

    task.cancel()

    do {
        _ = try await task.value
        Issue.record("Expected cancellation to stop the workflow")
    } catch is CancellationError {
        // Expected.
    }
}

@Test
func retriesOutputThatFailsValidation() async throws {
    let validator = WorkflowValidator<TestState> { state, _ in
        state.value >= 2 ? .valid : .invalid(reason: "Value must be at least 2")
    }
    let node = AnyWorkflowNode<TestState>(id: "generate") { state, context in
        var state = state
        state.value = context.attempt
        return .finish(state)
    }
    .validated(by: validator)
    let workflow = try Workflow(initialNode: "generate", nodes: [node])

    let run = try await workflow.run(TestState())

    #expect(run.state.value == 2)
    #expect(run.steps == 2)
    #expect(
        run.events.contains {
            guard case let .retryScheduled(_, nextAttempt, reason) = $0 else {
                return false
            }
            return nextAttempt == 2 && reason?.kind == .validation
        }
    )
}

@Test
func routesInvalidOutputToRepairNode() async throws {
    let validator = WorkflowValidator<TestState> { _, _ in
        .invalid(reason: "Needs repair")
    }
    let generate = AnyWorkflowNode<TestState>(id: "generate") { state, _ in
        .finish(state)
    }
    .validated(by: validator, onFailure: .route(to: "repair"))
    let repair = AnyWorkflowNode<TestState>(id: "repair") { state, _ in
        var state = state
        state.value = 42
        return .finish(state)
    }
    let workflow = try Workflow(
        initialNode: "generate",
        nodes: [generate, repair]
    )

    let run = try await workflow.run(TestState())

    #expect(run.state.value == 42)
    #expect(run.finalNode == "repair")
    #expect(run.outcome.wasRecovered)
    #expect(run.outcome.recoveries.first?.target == "repair")
    #expect(
        run.events.contains {
            guard case let .fallbackSelected(_, target, failure) = $0 else {
                return false
            }
            return target == "repair" && failure.kind == .validation
        }
    )
}

@Test
func recoversFromNodeErrorsUsingFallback() async throws {
    struct ExampleError: Error {}

    let unreliable = AnyWorkflowNode<TestState>(id: "unreliable") { _, _ in
        throw ExampleError()
    }
    .recover(to: "fallback")
    let fallback = AnyWorkflowNode<TestState>(id: "fallback") { state, _ in
        var state = state
        state.value = 99
        return .finish(state)
    }
    let workflow = try Workflow(
        initialNode: "unreliable",
        nodes: [unreliable, fallback]
    )

    let run = try await workflow.run(TestState())

    #expect(run.state.value == 99)
    #expect(run.finalNode == "fallback")
    #expect(run.outcome.wasRecovered)
    #expect(run.outcome.recoveries.first?.node == "unreliable")
    #expect(
        run.events.contains {
            guard case let .fallbackSelected(node, target, failure) = $0 else {
                return false
            }
            return node == "unreliable"
                && target == "fallback"
                && failure.kind == .execution
        }
    )
}

@Test
func timesOutSlowNodes() async throws {
    let slow = AnyWorkflowNode<TestState>(id: "slow") { state, _ in
        try await Task.sleep(for: .seconds(10))
        return .finish(state)
    }
    .timeout(after: .milliseconds(1))
    let workflow = try Workflow(initialNode: "slow", nodes: [slow])

    do {
        _ = try await workflow.run(TestState())
        Issue.record("Expected the node to time out")
    } catch let error as WorkflowExecutionError {
        #expect(
            error.workflowError
                == .nodeTimedOut(
                    node: "slow",
                    timeout: .milliseconds(1)
                )
        )
        #expect(error.failure.kind == .timeout)
    }
}

@Test
func allowsNodesToCompleteBeforeTimeout() async throws {
    let fast = AnyWorkflowNode<TestState>(id: "fast") { state, _ in
        var state = state
        state.value = 7
        return .finish(state)
    }
    .timeout(after: .seconds(1))
    let workflow = try Workflow(initialNode: "fast", nodes: [fast])

    let run = try await workflow.run(TestState())

    #expect(run.state.value == 7)
    #expect(run.finalNode == "fast")
}

@Test
func failsWorkflowWhenValidationIsConfiguredToFail() async throws {
    let validator = WorkflowValidator<TestState> { _, _ in
        .invalid(reason: "Rejected")
    }
    let node = AnyWorkflowNode<TestState>(id: "validate") { state, _ in
        .finish(state)
    }
    .validated(by: validator, onFailure: .fail)
    let workflow = try Workflow(initialNode: "validate", nodes: [node])

    do {
        _ = try await workflow.run(TestState())
        Issue.record("Expected validation to fail the workflow")
    } catch let error as WorkflowExecutionError {
        #expect(
            error.workflowError
                == .validationFailed(
                    node: "validate",
                    reason: "Rejected"
                )
        )
    }
}

@Test
func emitsStructuredFailureEvents() async throws {
    struct ExampleError: Error {}

    let recorder = EventRecorder()
    let node = AnyWorkflowNode<TestState>(id: "failure") { _, _ in
        throw ExampleError()
    }
    let workflow = try Workflow(initialNode: "failure", nodes: [node])

    var executionReport: WorkflowExecutionError?
    do {
        _ = try await workflow.run(TestState()) { event in
            await recorder.record(event)
        }
        Issue.record("Expected the node to fail")
    } catch let error as WorkflowExecutionError {
        executionReport = error
    }

    let events = await recorder.events
    let report = try #require(executionReport)
    #expect(report.events == events)
    #expect(report.node == "failure")
    #expect(report.failure.kind == .execution)
    #expect(
        events.contains {
            guard case let .workflowFailed(_, node, failure, steps) = $0 else {
                return false
            }
            return node == "failure"
                && failure.kind == .execution
                && steps == 1
        }
    )
}

@Test
func runsLanguageModelNodesThroughProviderNeutralInterface() async throws {
    let model = ClosureLanguageModel { request in
        LanguageModelResponse(
            content: request.prompt.uppercased(),
            provider: "test"
        )
    }
    let modelNode = LanguageModelNode<TestState>(
        id: "model",
        model: model,
        request: { state, _ in
            LanguageModelRequest(prompt: "value: \(state.value)")
        },
        reduce: { response, state, _ in
            var state = state
            state.route = response.content
            return .finish(state)
        }
    )
    let workflow = try Workflow(
        initialNode: "model",
        nodes: [AnyWorkflowNode(modelNode)]
    )

    let run = try await workflow.run(TestState(value: 3))

    #expect(run.state.route == "VALUE: 3")
    #expect(run.finalNode == "model")
}

@Test
func propagatesLanguageModelErrorsToWorkflowTracing() async throws {
    struct ProviderError: Error {}

    let model = ClosureLanguageModel { _ in
        throw ProviderError()
    }
    let modelNode = LanguageModelNode<TestState>(
        id: "model",
        model: model,
        request: { _, _ in LanguageModelRequest(prompt: "Hello") },
        reduce: { _, state, _ in .finish(state) }
    )
    let recorder = EventRecorder()
    let workflow = try Workflow(
        initialNode: "model",
        nodes: [AnyWorkflowNode(modelNode)]
    )

    var executionReport: WorkflowExecutionError?
    do {
        _ = try await workflow.run(TestState()) { event in
            await recorder.record(event)
        }
        Issue.record("Expected the provider to fail")
    } catch let error as WorkflowExecutionError {
        executionReport = error
    }

    let events = await recorder.events
    let report = try #require(executionReport)
    #expect(report.events == events)
    #expect(report.failure.errorType.contains("ProviderError"))
    #expect(
        events.contains {
            guard case let .nodeFailed(node, failure) = $0 else {
                return false
            }
            return node == "model" && failure.kind == .execution
        }
    )
}

@Test
func buildsWorkflowsDeclaratively() async throws {
    let includeFinish = true
    let start = AnyWorkflowNode<TestState>(id: "start") { state, _ in
        .next(state, "finish")
    }
    let finish = AnyWorkflowNode<TestState>(id: "finish") { state, _ in
        var state = state
        state.value = 12
        return .finish(state)
    }

    let workflow = try Workflow<TestState>(initialNode: "start") {
        start
        if includeFinish {
            finish
        }
    }

    let run = try await workflow.run(TestState())

    #expect(run.state.value == 12)
    #expect(run.outcome == .completed)
}

@Test
func composesNamespacedWorkflowComponents() async throws {
    let increment = AnyWorkflowNode<TestState>(id: "increment") { state, _ in
        var state = state
        state.value += 1
        return .next(state, "complete")
    }
    let complete = AnyWorkflowNode<TestState>(id: "complete") { state, _ in
        var state = state
        state.value *= 2
        return .finish(state)
    }
    let reusable = try WorkflowComponent<TestState>(entryNode: "increment") {
        increment
        complete
    }

    let second = reusable.namespaced("second")
    let first =
        reusable
        .namespaced("first")
        .continuing(to: second.entryNode)
    let workflow = try Workflow<TestState>(initialNode: first.entryNode) {
        first
        second
    }

    let run = try await workflow.run(TestState())

    #expect(run.state.value == 6)
    #expect(run.steps == 4)
    #expect(run.finalNode == "second.complete")
    #expect(first.nodeIDs.isDisjoint(with: second.nodeIDs))

    let startedNodes = run.events.compactMap { event -> NodeID? in
        guard case let .nodeStarted(node, _, _) = event else { return nil }
        return node
    }
    #expect(
        startedNodes == [
            "first.increment",
            "first.complete",
            "second.increment",
            "second.complete",
        ]
    )
}

@Test
func validatesWorkflowComponentDefinitions() throws {
    let node = AnyWorkflowNode<TestState>(id: "node") { state, _ in
        .finish(state)
    }

    do {
        _ = try WorkflowComponent<TestState>(entryNode: "missing") {
            node
        }
        Issue.record("Expected the component to reject a missing entry node")
    } catch let error as WorkflowError {
        #expect(error == .initialNodeNotFound("missing"))
    }

    do {
        _ = try WorkflowComponent<TestState>(entryNode: "node") {
            node
            node
        }
        Issue.record("Expected the component to reject duplicate node identifiers")
    } catch let error as WorkflowError {
        #expect(error == .duplicateNodeID("node"))
    }
}

@Test
func runsParallelBranchesAndMergesInDeclarationOrder() async throws {
    let completionOrder = StringRecorder()
    let parallel = try ParallelNode<TestState>(
        id: "parallel",
        branches: [
            ParallelBranch("slow") { state, _ in
                try await Task.sleep(for: .milliseconds(30))
                var state = state
                state.value = 1
                await completionOrder.append("slow")
                return state
            },
            ParallelBranch("fast") { state, _ in
                try await Task.sleep(for: .milliseconds(1))
                var state = state
                state.value = 2
                await completionOrder.append("fast")
                return state
            },
        ],
        continuation: .finish
    ) { initialState, results, _ in
        var state = initialState
        state.value =
            (results[branch: "slow"]?.value ?? 0)
            + (results[branch: "fast"]?.value ?? 0)
        state.route = results.ordered.map(\.name).joined(separator: ",")
        return state
    }
    let workflow = try Workflow<TestState>(initialNode: "parallel") {
        parallel
    }

    let run = try await workflow.run(TestState())

    #expect(await completionOrder.values == ["fast", "slow"])
    #expect(run.state.value == 3)
    #expect(run.state.route == "slow,fast")
    #expect(run.steps == 1)
    #expect(
        run.events.contains(
            .parallelBranchesCompleted(
                node: "parallel",
                branches: ["slow", "fast"]
            )
        )
    )
}

@Test
func reportsTheFailingParallelBranch() async throws {
    struct ExampleError: Error {}

    let parallel = try ParallelNode<TestState>(
        id: "parallel",
        branches: [
            ParallelBranch("failing") { _, _ in
                throw ExampleError()
            },
            ParallelBranch("cancelled-sibling") { state, _ in
                try await Task.sleep(for: .seconds(10))
                return state
            },
        ],
        continuation: .finish
    ) { state, _, _ in
        state
    }
    let workflow = try Workflow<TestState>(initialNode: "parallel") {
        parallel
    }

    do {
        _ = try await workflow.run(TestState())
        Issue.record("Expected the parallel branch to fail")
    } catch let error as WorkflowExecutionError {
        #expect(error.node == "parallel")
        #expect(error.failure.message == "The operation failed.")
        #expect(!error.failure.message.contains("ExampleError"))
        #expect(error.failure.errorType.contains("ParallelBranchExecutionError"))
    }
}

@Test
func validatesParallelNodeDefinitions() throws {
    do {
        _ = try ParallelNode<TestState>(
            id: "empty",
            branches: [],
            continuation: .finish
        ) { state, _, _ in state }
        Issue.record("Expected an empty parallel node to be rejected")
    } catch let error as WorkflowError {
        #expect(error == .parallelNodeHasNoBranches("empty"))
    }

    let duplicate = ParallelBranch<TestState>("duplicate") { state, _ in
        state
    }
    do {
        _ = try ParallelNode<TestState>(
            id: "duplicate-node",
            branches: [duplicate, duplicate],
            continuation: .finish
        ) { state, _, _ in state }
        Issue.record("Expected duplicate branch names to be rejected")
    } catch let error as WorkflowError {
        #expect(
            error
                == .duplicateParallelBranchName(
                    node: "duplicate-node",
                    name: "duplicate"
                )
        )
    }
}

@Test
func validatesParallelContinuationTargets() throws {
    let parallel = try ParallelNode<TestState>(
        id: "parallel",
        branches: [ParallelBranch("work") { state, _ in state }],
        continuation: .next("missing")
    ) { state, _, _ in state }

    do {
        _ = try Workflow<TestState>(initialNode: "parallel") {
            parallel
        }
        Issue.record("Expected the missing continuation target to be rejected")
    } catch let error as WorkflowError {
        #expect(
            error
                == .declaredDestinationNotFound(
                    from: "parallel",
                    target: "missing"
                )
        )
    }
}

@Test
func resumesFromCheckpointWithoutRepeatingCompletedNodes() async throws {
    let first = AnyWorkflowNode<TestState>(id: "first") { state, _ in
        var state = state
        state.value += 1
        return .next(state, "second")
    }
    let second = AnyWorkflowNode<TestState>(id: "second") { state, _ in
        var state = state
        state.value += 10
        return .finish(state)
    }
    let workflow = try Workflow<TestState>(
        definitionID: "resume-test-v1",
        initialNode: "first"
    ) {
        first
        second
    }
    let recorder = CheckpointRecorder<TestState>()

    _ = try await workflow.run(
        TestState(),
        onCheckpoint: { checkpoint in
            await recorder.record(checkpoint)
        })
    let checkpoints = await recorder.checkpoints
    let checkpoint = try #require(
        checkpoints.first { $0.nextNode == "second" }
    )

    let resumed = try await workflow.resume(from: checkpoint)

    #expect(resumed.state.value == 11)
    #expect(resumed.executionID == checkpoint.executionID)
    #expect(resumed.steps == 2)
    #expect(
        resumed.events.contains {
            guard case let .resumed(executionID, node, attempt, steps) = $0 else {
                return false
            }
            return executionID == checkpoint.executionID
                && node == "second"
                && attempt == 1
                && steps == 1
        }
    )

    let firstStarts = resumed.events.filter {
        guard case let .nodeStarted(node, _, _) = $0 else { return false }
        return node == "first"
    }
    #expect(firstStarts.count == 1)
}

@Test
func rejectsCheckpointsFromAnotherWorkflowDefinition() async throws {
    let node = AnyWorkflowNode<TestState>(id: "node") { state, _ in
        .finish(state)
    }
    let first = try Workflow<TestState>(
        definitionID: "first-v1",
        initialNode: "node"
    ) {
        node
    }
    let second = try Workflow<TestState>(
        definitionID: "second-v1",
        initialNode: "node"
    ) {
        node
    }
    let recorder = CheckpointRecorder<TestState>()

    _ = try await first.run(
        TestState(),
        onCheckpoint: { checkpoint in
            await recorder.record(checkpoint)
        })
    let savedCheckpoints = await recorder.checkpoints
    let checkpoint = try #require(savedCheckpoints.first)

    do {
        _ = try await second.resume(from: checkpoint)
        Issue.record("Expected the workflow definition mismatch to be rejected")
    } catch let error as WorkflowError {
        #expect(
            error
                == .checkpointDefinitionMismatch(
                    expected: "second-v1",
                    actual: "first-v1"
                )
        )
    }
}

@Test
func surfacesCheckpointHandlerFailuresBeforeRunningNodes() async throws {
    struct StorageError: Error {}

    let node = AnyWorkflowNode<TestState>(id: "node") { state, _ in
        .finish(state)
    }
    let workflow = try Workflow<TestState>(initialNode: "node") {
        node
    }

    do {
        _ = try await workflow.run(
            TestState(),
            onCheckpoint: { _ in
                throw StorageError()
            })
        Issue.record("Expected checkpoint persistence to fail")
    } catch let error as WorkflowExecutionError {
        #expect(error.node == "node")
        #expect(error.steps == 0)
        #expect(error.failure.errorType.contains("StorageError"))
        #expect(
            !error.events.contains {
                guard case .nodeStarted = $0 else { return false }
                return true
            }
        )
    }
}

@Test
func roundTripsCheckpointsThroughJSONFileStore() async throws {
    let node = AnyWorkflowNode<TestState>(id: "node") { state, _ in
        .finish(state)
    }
    let workflow = try Workflow<TestState>(
        definitionID: "json-test-v1",
        initialNode: "node"
    ) {
        node
    }
    let recorder = CheckpointRecorder<TestState>()
    _ = try await workflow.run(
        TestState(value: 7, route: "saved"),
        onCheckpoint: { checkpoint in
            await recorder.record(checkpoint)
        }
    )
    let savedCheckpoints = await recorder.checkpoints
    let checkpoint = try #require(savedCheckpoints.first)
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("swiftorc-\(UUID().uuidString).json")
    let store = JSONFileWorkflowCheckpointStore<TestState>(fileURL: fileURL)

    try await store.save(checkpoint)
    let loadedCheckpoint = try await store.load()
    let loaded = try #require(loadedCheckpoint)

    #expect(loaded.definitionID == checkpoint.definitionID)
    #expect(loaded.executionID == checkpoint.executionID)
    #expect(loaded.state == checkpoint.state)
    #expect(loaded.nextNode == checkpoint.nextNode)
    #expect(loaded.events == checkpoint.events)

    try await store.remove()
    let removedCheckpoint = try await store.load()
    #expect(removedCheckpoint == nil)
}

@Test
func checkpointStoreRejectsOversizedFilesBeforeDecoding() async throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("swiftorc-oversized-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try Data(repeating: 0x41, count: 64).write(to: fileURL)
    let store = JSONFileWorkflowCheckpointStore<TestState>(
        fileURL: fileURL,
        maximumBytes: 16
    )

    do {
        _ = try await store.load()
        Issue.record("Expected the oversized checkpoint to be rejected")
    } catch let error as JSONFileWorkflowCheckpointStoreError {
        #expect(error == .checkpointTooLarge(maximum: 16))
    }
}

@Test
func resumesWithTheCheckpointedRetryAttempt() async throws {
    let retry = AnyWorkflowNode<TestState>(id: "retry") { state, context in
        guard context.attempt > 1 else {
            return .retry(state)
        }
        var state = state
        state.value = context.attempt
        return .finish(state)
    }
    let workflow = try Workflow<TestState>(
        definitionID: "retry-resume-v1",
        initialNode: "retry"
    ) {
        retry
    }
    let recorder = CheckpointRecorder<TestState>()

    _ = try await workflow.run(
        TestState(),
        onCheckpoint: { checkpoint in
            await recorder.record(checkpoint)
        })
    let checkpoints = await recorder.checkpoints
    let retryCheckpoint = try #require(
        checkpoints.first { $0.attempt == 2 }
    )

    let resumed = try await workflow.resume(from: retryCheckpoint)

    #expect(resumed.state.value == 2)
    #expect(resumed.steps == 2)
}

@Test
func preservesRecoveryHistoryWhenResuming() async throws {
    struct ExampleError: Error {}

    let unreliable = AnyWorkflowNode<TestState>(id: "unreliable") { _, _ in
        throw ExampleError()
    }
    .recover(to: "repair")
    let repair = AnyWorkflowNode<TestState>(id: "repair") { state, _ in
        var state = state
        state.value = 42
        return .finish(state)
    }
    let workflow = try Workflow<TestState>(
        definitionID: "recovery-resume-v1",
        initialNode: "unreliable"
    ) {
        unreliable
        repair
    }
    let recorder = CheckpointRecorder<TestState>()

    _ = try await workflow.run(
        TestState(),
        onCheckpoint: { checkpoint in
            await recorder.record(checkpoint)
        })
    let checkpoints = await recorder.checkpoints
    let recoveryCheckpoint = try #require(
        checkpoints.first { $0.nextNode == "repair" }
    )

    let resumed = try await workflow.resume(from: recoveryCheckpoint)

    #expect(resumed.state.value == 42)
    #expect(resumed.outcome.wasRecovered)
    #expect(resumed.outcome.recoveries.first?.node == "unreliable")
}

@Test
func routesLanguageModelRequestsThroughFallbackProviders() async throws {
    struct PrimaryError: Error {}

    let calls = StringRecorder()
    let routingEvents = RoutingEventRecorder()
    let primary = ClosureLanguageModel { _ in
        await calls.append("primary")
        throw PrimaryError()
    }
    let fallback = ClosureLanguageModel { _ in
        await calls.append("fallback")
        return LanguageModelResponse(
            content: "fallback response",
            provider: "underlying-fallback"
        )
    }
    let router = try LanguageModelRouter(
        routes: [
            LanguageModelRoute(provider: "primary", model: primary),
            LanguageModelRoute(provider: "fallback", model: fallback),
        ],
        onEvent: { event in
            await routingEvents.record(event)
        }
    )

    let response = try await router.generate(
        LanguageModelRequest(prompt: "Hello")
    )

    #expect(await calls.values == ["primary", "fallback"])
    #expect(response.content == "fallback response")
    #expect(response.provider == "fallback")
    #expect(response.metadata["routing.upstream-provider"] == "underlying-fallback")

    let report = try #require(response.routingReport)
    #expect(report.selectedProvider == "fallback")
    #expect(report.attemptedProviders == ["primary", "fallback"])
    #expect(report.attempts.count == 2)
    if case let .failed(failure) = report.attempts[0].outcome {
        #expect(failure.errorType.contains("PrimaryError"))
    } else {
        Issue.record("Expected the primary provider failure to be recorded")
    }
    #expect(report.attempts[1].outcome == .selected)

    let events = await routingEvents.events
    #expect(events.count == 4)
    #expect(events[0] == .started(provider: "primary"))
    #expect(events[2] == .started(provider: "fallback"))
    #expect(events[3] == .selected(provider: "fallback"))
}

@Test
func routesThroughSecondaryProviderThenOnDeviceBeforeStaticFallback() async throws {
    struct ProviderError: Error {}

    let calls = StringRecorder()
    let unavailableRemote = ClosureLanguageModel { request in
        await calls.append(request.prompt)
        throw ProviderError()
    }
    let onDevice = ClosureLanguageModel { _ in
        await calls.append("on-device")
        return LanguageModelResponse(content: "local response")
    }
    let router = try LanguageModelRouter(routes: [
        LanguageModelRoute(
            provider: "primary-api",
            kind: .remote,
            model: unavailableRemote
        ),
        LanguageModelRoute(
            provider: "secondary-api",
            kind: .remote,
            model: unavailableRemote
        ),
        LanguageModelRoute(
            provider: "apple-on-device",
            kind: .onDevice,
            model: onDevice
        ),
        LanguageModelRoute(
            provider: "static-copy",
            kind: .staticFallback,
            model: StaticLanguageModel(content: "static response")
        ),
    ])

    let response = try await router.generate(
        LanguageModelRequest(
            prompt: "request",
            routingPolicy: .remoteThenOnDeviceAndStatic
        )
    )

    #expect(await calls.values == ["request", "request", "on-device"])
    #expect(response.content == "local response")
    #expect(response.provider == "apple-on-device")
    #expect(response.routingReport?.selectedKind == .onDevice)
    #expect(
        response.routingReport?.attemptedProviders
            == ["primary-api", "secondary-api", "apple-on-device"]
    )
    #expect(response.metadata["routing.selected-kind"] == "on-device")
}

@Test
func requestPolicyCanSelectOnlyAnExplicitProvider() async throws {
    let calls = StringRecorder()
    let model = ClosureLanguageModel { request in
        await calls.append(request.prompt)
        return LanguageModelResponse(content: request.prompt)
    }
    let router = try LanguageModelRouter(routes: [
        LanguageModelRoute(provider: "primary-api", model: model),
        LanguageModelRoute(provider: "secondary-api", model: model),
        LanguageModelRoute(
            provider: "static-copy",
            kind: .staticFallback,
            model: StaticLanguageModel(content: "static response")
        ),
    ])
    let policy = LanguageModelRoutingPolicy(
        allowedProviderIdentifiers: ["secondary-api"],
        allowedKinds: [.remote]
    )

    let response = try await router.generate(
        LanguageModelRequest(prompt: "request", routingPolicy: policy)
    )

    #expect(await calls.values == ["request"])
    #expect(response.provider == "secondary-api")
    #expect(response.routingReport?.attempts[0].outcome == .skipped)
    #expect(response.routingReport?.attempts[1].outcome == .selected)
}

@Test
func requestPolicyCanPreventStaticFallback() async throws {
    struct ProviderError: Error {}

    let staticCalls = StringRecorder()
    let failing = ClosureLanguageModel { _ in throw ProviderError() }
    let staticFallback = ClosureLanguageModel { _ in
        await staticCalls.append("called")
        return LanguageModelResponse(content: "static response")
    }
    let router = try LanguageModelRouter(routes: [
        LanguageModelRoute(provider: "api", model: failing),
        LanguageModelRoute(
            provider: "local",
            kind: .onDevice,
            model: failing
        ),
        LanguageModelRoute(
            provider: "static-copy",
            kind: .staticFallback,
            model: staticFallback
        ),
    ])

    do {
        _ = try await router.generate(
            LanguageModelRequest(
                prompt: "request",
                routingPolicy: .remoteThenOnDevice
            )
        )
        Issue.record("Expected eligible model providers to be exhausted")
    } catch let error as LanguageModelRoutingError {
        #expect(error.reason == .exhaustedProviders)
        #expect(error.report.attemptedProviders == ["api", "local"])
        #expect(error.report.attempts[2].outcome == .skipped)
    }
    #expect(await staticCalls.values.isEmpty)
}

@Test
func skipsIneligibleLanguageModelProviders() async throws {
    let calls = StringRecorder()
    let skipped = ClosureLanguageModel { _ in
        await calls.append("ineligible")
        return LanguageModelResponse(content: "wrong")
    }
    let selected = ClosureLanguageModel { _ in
        await calls.append("eligible")
        return LanguageModelResponse(content: "right")
    }
    let router = try LanguageModelRouter(routes: [
        LanguageModelRoute(
            provider: "ineligible",
            model: skipped,
            isEligible: { _ in false }
        ),
        LanguageModelRoute(provider: "eligible", model: selected),
    ])

    let response = try await router.generate(
        LanguageModelRequest(prompt: "Hello")
    )

    #expect(await calls.values == ["eligible"])
    #expect(response.provider == "eligible")
    #expect(response.routingReport?.attempts[0].outcome == .skipped)
}

@Test
func stopsLanguageModelFallbackWhenPolicyRequestsIt() async throws {
    struct ProviderError: Error {}

    let fallbackCalls = StringRecorder()
    let failing = ClosureLanguageModel { _ in throw ProviderError() }
    let fallback = ClosureLanguageModel { _ in
        await fallbackCalls.append("called")
        return LanguageModelResponse(content: "unexpected")
    }
    let router = try LanguageModelRouter(routes: [
        LanguageModelRoute(
            provider: "strict",
            model: failing,
            onFailure: { _ in .stop }
        ),
        LanguageModelRoute(provider: "fallback", model: fallback),
    ])

    do {
        _ = try await router.generate(LanguageModelRequest(prompt: "Hello"))
        Issue.record("Expected routing to stop after the strict provider")
    } catch let error as LanguageModelRoutingError {
        #expect(error.reason == .stopped(provider: "strict"))
        #expect(error.report.attemptedProviders == ["strict"])
    }
    #expect(await fallbackCalls.values.isEmpty)
}

@Test
func doesNotFallbackAfterLanguageModelCancellation() async throws {
    let fallbackCalls = StringRecorder()
    let cancelled = ClosureLanguageModel { _ in
        throw CancellationError()
    }
    let fallback = ClosureLanguageModel { _ in
        await fallbackCalls.append("called")
        return LanguageModelResponse(content: "unexpected")
    }
    let router = try LanguageModelRouter(routes: [
        LanguageModelRoute(provider: "cancelled", model: cancelled),
        LanguageModelRoute(provider: "fallback", model: fallback),
    ])

    do {
        _ = try await router.generate(LanguageModelRequest(prompt: "Hello"))
        Issue.record("Expected cancellation to stop model routing")
    } catch is CancellationError {
        // Expected.
    }
    #expect(await fallbackCalls.values.isEmpty)
}

@Test
func validatesLanguageModelRouterDefinitions() throws {
    do {
        _ = try LanguageModelRouter(routes: [])
        Issue.record("Expected an empty router to be rejected")
    } catch let error as LanguageModelRouterConfigurationError {
        #expect(error == .noRoutes)
    }

    let model = ClosureLanguageModel { _ in
        LanguageModelResponse(content: "response")
    }
    do {
        _ = try LanguageModelRouter(routes: [
            LanguageModelRoute(provider: "duplicate", model: model),
            LanguageModelRoute(provider: "duplicate", model: model),
        ])
        Issue.record("Expected duplicate provider identifiers to be rejected")
    } catch let error as LanguageModelRouterConfigurationError {
        #expect(error == .duplicateProviderIdentifier("duplicate"))
    }
}

@Test
func addsLanguageModelRoutingToWorkflowTrace() async throws {
    struct PrimaryError: Error {}

    let primary = ClosureLanguageModel { _ in throw PrimaryError() }
    let fallback = ClosureLanguageModel { _ in
        LanguageModelResponse(content: "routed response")
    }
    let router = try LanguageModelRouter(routes: [
        LanguageModelRoute(provider: "primary", model: primary),
        LanguageModelRoute(provider: "fallback", model: fallback),
    ])
    let modelNode = LanguageModelNode<TestState>(
        id: "model",
        model: router,
        request: { _, _ in LanguageModelRequest(prompt: "Hello") },
        reduce: { response, state, _ in
            var state = state
            state.route = response.provider ?? ""
            return .finish(state)
        }
    )
    let validator = WorkflowValidator<TestState> { _, _ in .valid }
    let validatedModel = AnyWorkflowNode(modelNode).validated(by: validator)
    let workflow = try Workflow<TestState>(initialNode: "model") {
        validatedModel
    }

    let run = try await workflow.run(TestState())

    #expect(run.state.route == "fallback")
    #expect(
        run.events.contains { event in
            guard
                case let .annotation(
                    node,
                    .languageModelRouting(report)
                ) = event
            else {
                return false
            }
            return node == "model"
                && report.selectedProvider == "fallback"
                && report.attemptedProviders == ["primary", "fallback"]
        }
    )
}

@Test
func reportsWhenNoLanguageModelProviderIsEligible() async throws {
    let model = ClosureLanguageModel { _ in
        LanguageModelResponse(content: "unexpected")
    }
    let router = try LanguageModelRouter(routes: [
        LanguageModelRoute(
            provider: "local-only",
            model: model,
            isEligible: { _ in false }
        )
    ])

    do {
        _ = try await router.generate(LanguageModelRequest(prompt: "Hello"))
        Issue.record("Expected routing to report no eligible provider")
    } catch let error as LanguageModelRoutingError {
        #expect(error.reason == .noEligibleProviders)
        #expect(error.report.selectedProvider == nil)
        #expect(error.report.attempts.first?.outcome == .skipped)
    }
}

@Test
func reportsWhenAllLanguageModelProvidersFail() async throws {
    struct ProviderError: Error {}

    let failing = ClosureLanguageModel { _ in throw ProviderError() }
    let router = try LanguageModelRouter(routes: [
        LanguageModelRoute(provider: "first", model: failing),
        LanguageModelRoute(provider: "second", model: failing),
    ])

    do {
        _ = try await router.generate(LanguageModelRequest(prompt: "Hello"))
        Issue.record("Expected all providers to be exhausted")
    } catch let error as LanguageModelRoutingError {
        #expect(error.reason == .exhaustedProviders)
        #expect(error.report.attemptedProviders == ["first", "second"])
        #expect(error.report.selectedProvider == nil)
    }
}

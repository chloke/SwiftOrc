import Foundation
import Testing

@testable import SwiftOrc

private actor AttemptCounter {
    private(set) var value = 0

    func increment() -> Int {
        value += 1
        return value
    }
}

private actor ConcurrencyCounter {
    private var active = 0
    private(set) var peak = 0

    func started() {
        active += 1
        peak = max(peak, active)
    }

    func finished() {
        active -= 1
    }
}

private actor DeltaRecorder {
    private(set) var value = ""

    func append(_ delta: String) {
        value += delta
    }
}

@Test
func workflowFailuresRedactUnknownErrorsAndPreserveExplicitFailures() {
    struct PrivateError: Error, CustomStringConvertible {
        var description: String { "private prompt contents" }
    }

    let redacted = WorkflowFailure(error: PrivateError())
    #expect(redacted.message == "The operation failed.")
    #expect(!redacted.message.contains("private prompt"))

    let explicit = WorkflowFailure(
        kind: .execution,
        message: "The imported document is unavailable.",
        errorType: "DocumentUnavailable"
    )
    #expect(WorkflowFailure(error: explicit) == explicit)
}

@Test
func retriesEligibleThrownNodeErrors() async throws {
    struct TransientError: Error {}
    let attempts = AttemptCounter()
    let node = AnyWorkflowNode<Int>(id: "retry") { state, _ in
        guard await attempts.increment() >= 3 else { throw TransientError() }
        return .finish(state + 1)
    }.retrying(
        WorkflowNodeRetryPolicy(maximumAttempts: 3) {
            $0 is TransientError
        }
    )
    let workflow = try Workflow(
        initialNode: "retry",
        nodes: [node],
        configuration: WorkflowConfiguration(maximumRetriesPerNode: 3)
    )

    let run = try await workflow.run(0)

    #expect(run.state == 1)
    #expect(await attempts.value == 3)
    #expect(
        run.events.filter {
            if case .retryScheduled = $0 { return true }
            return false
        }.count == 2
    )
}

@Test
func limitsParallelBranchConcurrency() async throws {
    let concurrency = ConcurrencyCounter()
    let branches = (0..<6).map { index in
        ParallelBranch<Int>("branch-\(index)") { state, _ in
            await concurrency.started()
            try await Task.sleep(for: .milliseconds(10))
            await concurrency.finished()
            return state + index
        }
    }
    let node = try ParallelNode(
        id: "parallel",
        branches: branches,
        continuation: .finish,
        maximumConcurrentBranches: 2
    ) { state, results, _ in
        state + results.ordered.reduce(0) { $0 + $1.state }
    }
    let workflow = try Workflow(initialNode: "parallel", nodes: [AnyWorkflowNode(node)])

    _ = try await workflow.run(0)

    #expect(await concurrency.peak == 2)
}

@Test
func exposesDeclaredWorkflowGraph() throws {
    let first = AnyWorkflowNode<Int>(
        id: "first",
        declaredDestinations: ["finish"]
    ) { state, _ in .next(state, "finish") }
    let finish = AnyWorkflowNode<Int>(id: "finish") { state, _ in .finish(state) }
    let workflow = try Workflow(initialNode: "first", nodes: [finish, first])

    #expect(workflow.declaredGraph.initialNode == "first")
    #expect(workflow.declaredGraph.nodes.map(\.id) == ["finish", "first"])
    #expect(workflow.declaredGraph.nodes[1].destinations == ["finish"])
}

@Test
func streamsDeltasThroughAWorkflowNode() async throws {
    let deltas = DeltaRecorder()
    let model = ClosureStreamingLanguageModel { _ in
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("Hel"))
            continuation.yield(.textDelta("lo"))
            continuation.yield(.completed(LanguageModelResponse(content: "Hello")))
            continuation.finish()
        }
    }
    let node = StreamingLanguageModelNode<Int>(
        id: "stream",
        model: model,
        request: { _, _ in LanguageModelRequest(prompt: "Say hello") },
        onDelta: { delta, _ in await deltas.append(delta) },
        reduce: { response, state, _ in
            #expect(response.content == "Hello")
            return .finish(state + 1)
        }
    )
    let workflow = try Workflow(initialNode: "stream", nodes: [AnyWorkflowNode(node)])

    let run = try await workflow.run(0)

    #expect(run.state == 1)
    #expect(await deltas.value == "Hello")
}

@Test
func streamingRouterSkipsNonStreamingRoutes() async throws {
    let streaming = ClosureStreamingLanguageModel { _ in
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("local"))
            continuation.yield(
                .completed(LanguageModelResponse(content: "local"))
            )
            continuation.finish()
        }
    }
    let router = try LanguageModelRouter(
        routes: [
            LanguageModelRoute(
                provider: "non-streaming",
                model: StaticLanguageModel(content: "wrong")
            ),
            LanguageModelRoute(provider: "streaming", model: streaming),
        ]
    )

    var deltas = ""
    var completed: LanguageModelResponse?
    for try await event in router.stream(
        LanguageModelRequest(prompt: "Generate")
    ) {
        switch event {
        case let .textDelta(delta):
            deltas += delta
        case let .completed(response):
            completed = response
        }
    }

    #expect(deltas == "local")
    let response = try #require(completed)
    #expect(response.provider == "streaming")
    let report = try #require(response.routingReport)
    #expect(report.selectedProvider == "streaming")
    #expect(report.requiredCapabilities.contains(.streaming))
    #expect(
        report.attempts[0].skipReason
            == .missingCapabilities([.streaming])
    )
}

@Test
func streamingRouterFallsBackOnlyBeforeEmittingText() async throws {
    struct ProviderFailure: Error {}
    let failing = ClosureStreamingLanguageModel { _ in
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ProviderFailure())
        }
    }
    let fallback = ClosureStreamingLanguageModel { _ in
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("fallback"))
            continuation.yield(
                .completed(LanguageModelResponse(content: "fallback"))
            )
            continuation.finish()
        }
    }
    let router = try LanguageModelRouter(
        routes: [
            LanguageModelRoute(provider: "first", model: failing),
            LanguageModelRoute(provider: "second", model: fallback),
        ]
    )

    var completed: LanguageModelResponse?
    for try await event in router.stream(
        LanguageModelRequest(prompt: "Generate")
    ) {
        if case let .completed(response) = event {
            completed = response
        }
    }

    let report = try #require(completed?.routingReport)
    #expect(report.selectedProvider == "second")
    #expect(report.attemptedProviders == ["first", "second"])
}

@Test
func streamingRouterDoesNotMixProvidersAfterAPartialResponse() async throws {
    struct ProviderFailure: Error {}
    let partial = ClosureStreamingLanguageModel { _ in
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("partial"))
            continuation.finish(throwing: ProviderFailure())
        }
    }
    let fallback = ClosureStreamingLanguageModel { _ in
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("wrong-provider"))
            continuation.yield(
                .completed(LanguageModelResponse(content: "wrong-provider"))
            )
            continuation.finish()
        }
    }
    let router = try LanguageModelRouter(
        routes: [
            LanguageModelRoute(provider: "partial", model: partial),
            LanguageModelRoute(provider: "fallback", model: fallback),
        ]
    )

    var deltas = ""
    do {
        for try await event in router.stream(
            LanguageModelRequest(prompt: "Generate")
        ) {
            if case let .textDelta(delta) = event {
                deltas += delta
            }
        }
        Issue.record("Expected routing to stop after a partial response")
    } catch let error as LanguageModelRoutingError {
        #expect(error.reason == .stopped(provider: "partial"))
        #expect(error.report.attemptedProviders == ["partial"])
    }
    #expect(deltas == "partial")
}

import Foundation
import SwiftOrc
import SwiftOrcTesting
import Testing

private struct ProbeState: Sendable, Equatable {
    var value = 0
}

private enum ProbeError: Error {
    case expectedFailure
}

@Test
func scriptedModelReturnsStepsInOrderAndRecordsRequests() async throws {
    let model = ScriptedLanguageModel(
        .respond(content: "first"),
        .respond(
            content: "second",
            provider: "second-provider",
            metadata: ["fixture": "two"]
        )
    )
    let firstRequest = LanguageModelRequest(prompt: "request one")
    let secondRequest = LanguageModelRequest(
        prompt: "request two",
        routingPolicy: .onDeviceOnly
    )

    let first = try await model.generate(firstRequest)
    let second = try await model.generate(secondRequest)
    let snapshot = await model.snapshot()

    #expect(first.content == "first")
    #expect(first.provider == ScriptedLanguageModel.providerIdentifier)
    #expect(second.content == "second")
    #expect(second.provider == "second-provider")
    #expect(second.metadata["fixture"] == "two")
    #expect(snapshot.requests == [firstRequest, secondRequest])
    #expect(snapshot.consumedStepCount == 2)
    #expect(snapshot.remainingStepCount == 0)
    #expect(snapshot.allStepsConsumed)
}

@Test
func scriptedModelThrowsConfiguredFailuresAndCanBeReset() async throws {
    let failure = WorkflowFailure(
        kind: .routing,
        message: "provider unavailable",
        errorType: "FixtureFailure"
    )
    let model = ScriptedLanguageModel(
        .fail(with: failure),
        .respond(content: "recovered")
    )

    do {
        _ = try await model.generate(LanguageModelRequest(prompt: "first"))
        Issue.record("Expected the first scripted step to fail")
    } catch let received as WorkflowFailure {
        #expect(received == failure)
    }

    let response = try await model.generate(
        LanguageModelRequest(prompt: "second")
    )
    #expect(response.content == "recovered")

    await model.reset()
    let resetSnapshot = await model.snapshot()
    #expect(resetSnapshot.requests.isEmpty)
    #expect(resetSnapshot.consumedStepCount == 0)
    #expect(resetSnapshot.remainingStepCount == 2)
}

@Test
func scriptedModelExhaustionDoesNotExposePromptContent() async throws {
    let privatePrompt = "private fixture content"
    let model = ScriptedLanguageModel(steps: [])

    do {
        _ = try await model.generate(
            LanguageModelRequest(prompt: privatePrompt)
        )
        Issue.record("Expected the empty script to be exhausted")
    } catch let error as ScriptedLanguageModelError {
        #expect(error == .scriptExhausted(requestNumber: 1))
        #expect(!error.description.contains(privatePrompt))
    }
}

@Test
func scriptedFailureExercisesRealRouterFallback() async throws {
    let unavailable = ScriptedLanguageModel(
        .fail(message: "local model unavailable")
    )
    let fallback = ScriptedLanguageModel(
        .respond(content: "fallback answer", provider: "fallback")
    )
    let router = try LanguageModelRouter(
        routes: [
            LanguageModelRoute(
                provider: "local",
                kind: .onDevice,
                model: unavailable
            ),
            LanguageModelRoute(
                provider: "fallback",
                kind: .staticFallback,
                model: fallback
            ),
        ]
    )

    let response = try await router.generate(
        LanguageModelRequest(
            prompt: "test fallback",
            routingPolicy: .automatic
        )
    )

    let unavailableRequests = await unavailable.recordedRequests()
    let fallbackRequests = await fallback.recordedRequests()
    #expect(response.content == "fallback answer")
    #expect(response.routingReport?.selectedProvider == "fallback")
    #expect(unavailableRequests.count == 1)
    #expect(fallbackRequests.count == 1)
}

@Test
func workflowProbeRecordsRetriesRoutesAndCheckpoints() async throws {
    let retry = AnyWorkflowNode<ProbeState>(
        id: "retry",
        declaredDestinations: ["branch"]
    ) { state, context in
        if context.attempt == 1 {
            return .retry(state)
        }
        return .next(state, "branch")
    }
    let branch = BranchNode<ProbeState>(
        id: "branch",
        routes: [
            BranchRoute("ready", to: "finish") { _, _ in true }
        ],
        defaultTarget: "finish"
    )
    let finish = AnyWorkflowNode<ProbeState>(id: "finish") { state, _ in
        .finish(state)
    }
    let workflow = try Workflow<ProbeState>(
        definitionID: "probe-fixture",
        initialNode: "retry",
        configuration: WorkflowConfiguration(maximumRetriesPerNode: 1)
    ) {
        retry
        branch
        finish
    }
    let probe = WorkflowProbe<ProbeState>()

    _ = try await workflow.run(
        ProbeState(),
        onEvent: probe.eventHandler,
        onCheckpoint: probe.checkpointHandler
    )
    let snapshot = await probe.snapshot()

    #expect(snapshot.startCount(for: "retry") == 2)
    #expect(snapshot.selectedRoutes(for: "branch") == ["ready"])
    #expect(snapshot.checkpoints.first?.nextNode == "retry")
    #expect(snapshot.checkpoints.last?.nextNode == "finish")

    await probe.reset()
    let emptySnapshot = await probe.snapshot()
    #expect(emptySnapshot.events.isEmpty)
    #expect(emptySnapshot.checkpoints.isEmpty)
}

@Test
func workflowProbeFindsFallbackTargets() async throws {
    let failing = AnyWorkflowNode<ProbeState>(id: "failing") { _, _ in
        throw ProbeError.expectedFailure
    }
    .recover(to: "fallback")
    let fallback = AnyWorkflowNode<ProbeState>(id: "fallback") { state, _ in
        .finish(state)
    }
    let workflow = try Workflow<ProbeState>(initialNode: "failing") {
        failing
        fallback
    }
    let probe = WorkflowProbe<ProbeState>()

    _ = try await workflow.run(
        ProbeState(),
        onEvent: probe.eventHandler
    )
    let snapshot = await probe.snapshot()

    #expect(snapshot.fallbackTargets(from: "failing") == ["fallback"])
}

@Test
func delayedScriptedStepRespectsCancellation() async throws {
    let model = ScriptedLanguageModel(
        .respond(content: "too late", after: .seconds(30))
    )
    let task = Task {
        try await model.generate(LanguageModelRequest(prompt: "wait"))
    }

    await Task.yield()
    task.cancel()

    do {
        _ = try await task.value
        Issue.record("Expected cancellation to stop the delayed step")
    } catch is CancellationError {
        // Expected.
    }
}

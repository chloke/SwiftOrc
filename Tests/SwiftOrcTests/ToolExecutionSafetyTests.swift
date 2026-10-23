import Foundation
import Testing

@testable import SwiftOrc

private actor InvocationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private struct NoArguments: Decodable, Sendable {}

private struct Acknowledgement: Encodable, Sendable {
    let ok: Bool
}

private func countingTool(
    _ counter: InvocationCounter
) -> ClosureLanguageModelTool<NoArguments, Acknowledgement> {
    ClosureLanguageModelTool(
        definition: LanguageModelToolDefinition(
            name: "charge",
            description: "Charges a payment method.",
            parameters: .objectSchema(properties: [:], required: [])
        ),
        call: { _ in
            await counter.increment()
            return Acknowledgement(ok: true)
        }
    )
}

/// Requests one tool call, then fails as if the provider went away after the
/// tool had already run.
private func failingAfterToolCallModel() -> ClosureLanguageModel {
    let calls = InvocationCounter()
    return ClosureLanguageModel { _ in
        await calls.increment()
        guard await calls.value == 1 else { throw URLError(.timedOut) }
        return LanguageModelResponse(
            content: "",
            toolCalls: [
                LanguageModelToolCall(id: "call-1", name: "charge", arguments: "{}")
            ]
        )
    }
}

private func toolRoute(
    _ provider: String,
    counter: InvocationCounter,
    metadata: LanguageModelToolMetadata
) throws -> LanguageModelRoute {
    LanguageModelRoute(
        provider: provider,
        model: try ToolCallingLanguageModel(
            model: failingAfterToolCallModel(),
            registrations: [
                LanguageModelToolRegistration(
                    tool: countingTool(counter),
                    metadata: metadata
                )
            ]
        )
    )
}

@Test
func routerDoesNotFallBackAfterSideEffectingToolRan() async throws {
    let charges = InvocationCounter()
    let router = try LanguageModelRouter(routes: [
        try toolRoute("primary", counter: charges, metadata: .unclassified),
        try toolRoute("secondary", counter: charges, metadata: .unclassified),
    ])

    do {
        _ = try await router.generate(LanguageModelRequest(prompt: "Pay"))
        Issue.record("Expected routing to stop")
    } catch let error as LanguageModelRoutingError {
        #expect(error.reason == .stopped(provider: "primary"))
        #expect(error.report.attemptedProviders == ["primary"])
    }
    #expect(await charges.value == 1)
}

@Test
func routerStillFallsBackAfterReadOnlyToolRan() async throws {
    let lookups = InvocationCounter()
    let readOnly = LanguageModelToolMetadata(risk: .minimal, effects: [.readOnly])
    let router = try LanguageModelRouter(routes: [
        try toolRoute("primary", counter: lookups, metadata: readOnly),
        LanguageModelRoute(
            provider: "secondary",
            model: StaticLanguageModel(content: "fallback")
        ),
    ])

    let response = try await router.generate(LanguageModelRequest(prompt: "Look up"))

    #expect(response.content == "fallback")
    #expect(await lookups.value == 1)
}

@Test
func streamingRouterDoesNotFallBackAfterSideEffectingToolRan() async throws {
    let charges = InvocationCounter()
    let toolModel = try ToolCallingLanguageModel(
        model: ClosureLanguageModel { request in
            request.messages.isEmpty
                ? LanguageModelResponse(
                    content: "",
                    toolCalls: [
                        LanguageModelToolCall(id: "call-1", name: "charge", arguments: "{}")
                    ]
                )
                : LanguageModelResponse(content: "charged")
        },
        tools: [countingTool(charges)]
    )
    // Runs a tool, then fails before emitting any text.
    let streaming = ClosureStreamingLanguageModel { request in
        AsyncThrowingStream { continuation in
            Task {
                _ = try? await toolModel.generate(request)
                continuation.finish(throwing: URLError(.networkConnectionLost))
            }
        }
    }
    let router = try LanguageModelRouter(routes: [
        LanguageModelRoute(provider: "primary", model: streaming),
        LanguageModelRoute(provider: "secondary", model: streaming),
    ])

    do {
        for try await _ in router.stream(LanguageModelRequest(prompt: "Pay")) {}
        Issue.record("Expected routing to stop")
    } catch let error as LanguageModelRoutingError {
        #expect(error.reason == .stopped(provider: "primary"))
    }
    #expect(await charges.value == 1)
}

@Test
func sideEffectsRecordedInNestedRouterReachOuterRouter() async throws {
    let charges = InvocationCounter()
    let inner = try LanguageModelRouter(routes: [
        try toolRoute("inner", counter: charges, metadata: .unclassified)
    ])
    let outer = try LanguageModelRouter(routes: [
        LanguageModelRoute(provider: "nested", model: inner),
        try toolRoute("outer-fallback", counter: charges, metadata: .unclassified),
    ])

    do {
        _ = try await outer.generate(LanguageModelRequest(prompt: "Pay"))
        Issue.record("Expected routing to stop")
    } catch let error as LanguageModelRoutingError {
        #expect(error.reason == .stopped(provider: "nested"))
    }
    #expect(await charges.value == 1)
}

private func busyTool(seconds: Double) -> ClosureLanguageModelTool<NoArguments, Acknowledgement> {
    ClosureLanguageModelTool(
        definition: LanguageModelToolDefinition(
            name: "busy",
            description: "Blocks without checking for cancellation.",
            parameters: .objectSchema(properties: [:], required: [])
        ),
        call: { _ in
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {}
            return Acknowledgement(ok: true)
        }
    )
}

@Test
func toolTimeoutIsHonoredWhenToolIgnoresCancellation() async throws {
    let executor = try LanguageModelToolExecutor(registrations: [
        LanguageModelToolRegistration(
            tool: busyTool(seconds: 1.5),
            policy: LanguageModelToolExecutionPolicy(timeout: .milliseconds(100))
        )
    ])
    let clock = ContinuousClock()
    let start = clock.now

    do {
        _ = try await executor.execute(
            LanguageModelToolCall(id: "call-1", name: "busy", arguments: "{}"),
            context: LanguageModelToolExecutionContext(round: 1, callNumber: 1, provider: nil)
        )
        Issue.record("Expected the tool to time out")
    } catch let error as LanguageModelToolPolicyError {
        #expect(error == .timedOut(tool: "busy"))
    }
    #expect(clock.now - start < .milliseconds(800))
}

@Test
func timedOutToolKeepsItsConcurrencyPermitUntilItStops() async throws {
    let counter = InvocationCounter()
    let executor = try LanguageModelToolExecutor(
        registrations: [
            LanguageModelToolRegistration(
                tool: busyTool(seconds: 1),
                policy: LanguageModelToolExecutionPolicy(timeout: .milliseconds(100))
            ),
            LanguageModelToolRegistration(tool: countingTool(counter)),
        ],
        maximumConcurrentCalls: 1
    )
    let context = LanguageModelToolExecutionContext(round: 1, callNumber: 1, provider: nil)
    let clock = ContinuousClock()
    let start = clock.now

    _ = try? await executor.execute(
        LanguageModelToolCall(id: "call-1", name: "busy", arguments: "{}"),
        context: context
    )
    _ = try await executor.execute(
        LanguageModelToolCall(id: "call-2", name: "charge", arguments: "{}"),
        context: context
    )

    // The second call may start only once the abandoned work has finished.
    #expect(clock.now - start >= .milliseconds(900))
    #expect(await counter.value == 1)
}

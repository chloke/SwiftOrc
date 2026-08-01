import Testing

@testable import SwiftOrc

private enum ExampleGeneration: Sendable {
    case model26
    case model27
    case unsupported
}

private struct VersionAwareExampleState: Sendable {
    let generation: ExampleGeneration
    let localAvailable: Bool
    var selected = ""
}

private struct SimulatedProviderFailure: Error, Sendable {}

private actor ProviderCallLog {
    private(set) var providers: [String] = []

    func record(_ provider: String) {
        providers.append(provider)
    }
}

private func makeVersionAwareExample(
    remoteAllowed: Bool,
    remoteSucceeds: Bool,
    calls: ProviderCallLog
) throws -> Workflow<VersionAwareExampleState> {
    let select = BranchNode<VersionAwareExampleState>(
        id: "select-version",
        routes: [
            BranchRoute("model-27", to: "task-v27") { state, _ in
                state.generation == .model27 && state.localAvailable
            },
            BranchRoute("model-26", to: "task-v26") { state, _ in
                state.generation == .model26 && state.localAvailable
            },
        ],
        defaultTarget: "fallback"
    )
    let model27 = AnyWorkflowNode<VersionAwareExampleState>(id: "task-v27") {
        state,
        _ in
        var state = state
        state.selected = "task-v27"
        return .finish(state)
    }
    let model26 = AnyWorkflowNode<VersionAwareExampleState>(id: "task-v26") {
        state,
        _ in
        var state = state
        state.selected = "task-v26"
        return .finish(state)
    }
    let remote = ClosureLanguageModel { _ in
        await calls.record("mock-remote")
        guard remoteSucceeds else { throw SimulatedProviderFailure() }
        return LanguageModelResponse(content: "remote")
    }
    let staticModel = ClosureLanguageModel { _ in
        await calls.record("static")
        return LanguageModelResponse(content: "static")
    }
    let router = try LanguageModelRouter(routes: [
        LanguageModelRoute(
            provider: "mock-remote",
            kind: .remote,
            model: remote
        ),
        LanguageModelRoute(
            provider: "static",
            kind: .staticFallback,
            model: staticModel
        ),
    ])
    let policy =
        remoteAllowed
        ? LanguageModelRoutingPolicy(allowedKinds: [.remote, .staticFallback])
        : .staticFallbackOnly
    let fallback = LanguageModelNode<VersionAwareExampleState>(
        id: "fallback",
        model: router,
        request: { _, _ in
            LanguageModelRequest(prompt: "example", routingPolicy: policy)
        },
        reduce: { response, state, _ in
            var state = state
            state.selected = response.provider ?? "none"
            return .finish(state)
        }
    )

    return try Workflow(initialNode: "select-version") {
        select
        model27
        model26
        fallback
    }
}

@Test
func versionAwareExampleSelectsValidatedLocalNode() async throws {
    let calls = ProviderCallLog()
    let workflow = try makeVersionAwareExample(
        remoteAllowed: true,
        remoteSucceeds: true,
        calls: calls
    )

    let run = try await workflow.run(
        VersionAwareExampleState(
            generation: .model27,
            localAvailable: true
        )
    )

    #expect(run.state.selected == "task-v27")
    #expect(await calls.providers.isEmpty)
}

@Test
func versionAwareExampleCannotCallRemoteWhenPolicyForbidsIt() async throws {
    let calls = ProviderCallLog()
    let workflow = try makeVersionAwareExample(
        remoteAllowed: false,
        remoteSucceeds: true,
        calls: calls
    )

    let run = try await workflow.run(
        VersionAwareExampleState(
            generation: .unsupported,
            localAvailable: false
        )
    )

    #expect(run.state.selected == "static")
    #expect(await calls.providers == ["static"])
}

@Test
func versionAwareExampleUsesStaticCopyAfterMockRemoteFailure() async throws {
    let calls = ProviderCallLog()
    let workflow = try makeVersionAwareExample(
        remoteAllowed: true,
        remoteSucceeds: false,
        calls: calls
    )

    let run = try await workflow.run(
        VersionAwareExampleState(
            generation: .model26,
            localAvailable: false
        )
    )

    #expect(run.state.selected == "static")
    #expect(await calls.providers == ["mock-remote", "static"])
}

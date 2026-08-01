import Foundation
import Testing

@testable import SwiftOrc

private actor CapabilityCallRecorder {
    private(set) var providers: [String] = []

    func record(_ provider: String) {
        providers.append(provider)
    }
}

private actor CapabilityEventRecorder {
    private(set) var events: [LanguageModelRoutingEvent] = []

    func record(_ event: LanguageModelRoutingEvent) {
        events.append(event)
    }
}

private let capabilityTestSchema = LanguageModelJSONSchema(
    name: "safety_result",
    schema: .objectSchema(
        properties: [
            "safe": .object(["type": .string("boolean")])
        ],
        required: ["safe"]
    )
)

@Test
func infersTechnicalCapabilitiesFromRequestFeatures() {
    let request = LanguageModelRequest(
        prompt: "Inspect the image.",
        requiredCapabilities: ["content-moderation"],
        input: [
            .image(
                LanguageModelImage(
                    source: .data(Data([1]), mediaType: "image/png")
                )
            )
        ],
        tools: [
            LanguageModelToolDefinition(
                name: "lookup",
                description: "Looks up a value.",
                parameters: .objectSchema(properties: [:], required: [])
            )
        ],
        parallelToolCalls: true,
        responseFormat: .jsonSchema(capabilityTestSchema)
    )

    #expect(
        request.effectiveRequiredCapabilities == [
            .textInput,
            .imageInput,
            .structuredOutput,
            .toolCalling,
            .parallelToolCalling,
            "content-moderation",
        ]
    )
}

@Test
func explicitToolChoiceNoneDoesNotRequireToolCalling() {
    let request = LanguageModelRequest(
        prompt: "Answer without tools.",
        tools: [
            LanguageModelToolDefinition(
                name: "unused",
                description: "Not available for this request.",
                parameters: .objectSchema(properties: [:], required: [])
            )
        ],
        toolChoice: LanguageModelToolChoice.none
    )

    #expect(request.effectiveRequiredCapabilities == [.textInput])
}

@Test
func conversationMessagesRequireConversationHistoryCapability() {
    let request = LanguageModelRequest(
        prompt: "Continue.",
        messages: [.assistant(content: "Earlier response", toolCalls: [])]
    )

    #expect(
        request.effectiveRequiredCapabilities == [
            .textInput,
            .conversationHistory,
        ]
    )
}

@Test
func routerSkipsDeclaredRoutesMissingImageSupport() async throws {
    let calls = CapabilityCallRecorder()
    let events = CapabilityEventRecorder()
    let textOnly = ClosureLanguageModel { _ in
        await calls.record("text-only")
        return LanguageModelResponse(content: "wrong")
    }
    let vision = ClosureLanguageModel { _ in
        await calls.record("vision")
        return LanguageModelResponse(content: "safe")
    }
    let router = try LanguageModelRouter(
        routes: [
            LanguageModelRoute(
                provider: "text-only",
                capabilities: [.textInput],
                model: textOnly
            ),
            LanguageModelRoute(
                provider: "vision",
                capabilities: [.textInput, .imageInput],
                model: vision
            ),
        ],
        onEvent: { await events.record($0) }
    )

    let response = try await router.generate(
        LanguageModelRequest(
            prompt: "Inspect this image.",
            input: [
                .image(
                    LanguageModelImage(
                        source: .data(Data([1]), mediaType: "image/png")
                    )
                )
            ]
        )
    )

    #expect(await calls.providers == ["vision"])
    #expect(response.provider == "vision")
    let report = try #require(response.routingReport)
    #expect(report.attemptedProviders == ["vision"])
    #expect(report.requiredCapabilities == [.textInput, .imageInput])
    #expect(
        report.attempts[0].skipReason
            == .missingCapabilities([.imageInput])
    )
    #expect(report.attempts[1].outcome == .selected)
    #expect(
        await events.events.first
            == .skippedForCapabilities(
                provider: "text-only",
                missing: [.imageInput]
            )
    )
}

@Test
func routerReportsWhenNoDeclaredRouteIsCompatible() async throws {
    let calls = CapabilityCallRecorder()
    let textOnly = ClosureLanguageModel { _ in
        await calls.record("called")
        return LanguageModelResponse(content: "unexpected")
    }
    let router = try LanguageModelRouter(routes: [
        LanguageModelRoute(
            provider: "text-only",
            capabilities: [.textInput],
            model: textOnly
        )
    ])
    let request = LanguageModelRequest(
        prompt: "Inspect this image.",
        requiredCapabilities: ["content-moderation"],
        input: [
            .image(
                LanguageModelImage(
                    source: .data(Data([1]), mediaType: "image/png")
                )
            )
        ],
        responseFormat: .jsonSchema(capabilityTestSchema)
    )

    do {
        _ = try await router.generate(request)
        Issue.record("Expected the router to find no compatible provider")
    } catch let error as LanguageModelRoutingError {
        #expect(
            error.reason
                == .noCompatibleProviders(
                    request.effectiveRequiredCapabilities
                )
        )
        guard
            case let .missingCapabilities(missing) = error.report
                .attempts[0].skipReason
        else {
            Issue.record("Expected a capability skip reason")
            return
        }
        #expect(
            missing == [
                .imageInput,
                .structuredOutput,
                "content-moderation",
            ]
        )
    }
    #expect(await calls.providers.isEmpty)
}

@Test
func unspecifiedCapabilitiesPreserveAttemptAndFallbackBehavior() async throws {
    let calls = CapabilityCallRecorder()
    let unspecified = ClosureLanguageModel { _ in
        await calls.record("unspecified")
        return LanguageModelResponse(content: "handled")
    }
    let router = try LanguageModelRouter(routes: [
        LanguageModelRoute(provider: "legacy", model: unspecified)
    ])

    let response = try await router.generate(
        LanguageModelRequest(
            prompt: "Inspect this image.",
            input: [
                .image(
                    LanguageModelImage(
                        source: .data(Data([1]), mediaType: "image/png")
                    )
                )
            ]
        )
    )

    #expect(response.provider == "legacy")
    #expect(await calls.providers == ["unspecified"])
}

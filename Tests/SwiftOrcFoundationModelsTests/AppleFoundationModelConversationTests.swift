import Foundation
import FoundationModels
import SwiftOrc
import Testing

@testable import SwiftOrcFoundationModels

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private actor MockAppleTextSession: AppleFoundationModelTextSession {
    let label: String
    let delay: Duration
    private(set) var prompts: [String] = []
    private(set) var prewarmPrefixes: [String?] = []
    private(set) var peakConcurrentResponses = 0
    private var activeResponses = 0

    init(label: String = "response", delay: Duration = .zero) {
        self.label = label
        self.delay = delay
    }

    func respond(
        to prompt: String,
        options _: GenerationOptions
    ) async throws -> String {
        prompts.append(prompt)
        activeResponses += 1
        peakConcurrentResponses = max(peakConcurrentResponses, activeResponses)
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        activeResponses -= 1
        return "\(label)-\(prompts.count)"
    }

    func prewarm(promptPrefix: String?) async {
        prewarmPrefixes.append(promptPrefix)
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private final class MockAppleSessionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [MockAppleTextSession]

    init(_ sessions: [MockAppleTextSession]) {
        self.sessions = sessions
    }

    func make() -> any AppleFoundationModelTextSession {
        lock.lock()
        defer { lock.unlock() }
        return sessions.removeFirst()
    }
}

@Test
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
func statelessAppleAdapterRejectsExplicitConversationHistory() async throws {
    let model = AppleFoundationModel()

    do {
        _ = try await model.generate(
            LanguageModelRequest(
                prompt: "Continue",
                messages: [.assistant(content: "Earlier", toolCalls: [])]
            )
        )
        Issue.record("Expected explicit history to be rejected")
    } catch let error as AppleFoundationModelError {
        #expect(
            error
                == .unsupportedInput(
                    kind: LanguageModelCapability.conversationHistory.rawValue
                )
        )
    }
}

@Test
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
func statefulAppleConversationReusesItsInjectedSession() async throws {
    let session = MockAppleTextSession()
    let conversation = AppleFoundationModelConversation(
        session: session,
        sessionFactory: { session }
    )

    try await conversation.prewarm(promptPrefix: "Story")
    let first = try await conversation.generate(
        LanguageModelRequest(prompt: "Hello")
    )
    let second = try await conversation.generate(
        LanguageModelRequest(
            prompt: "Continue",
            instructions: "Be concise"
        )
    )

    #expect(first.content == "response-1")
    #expect(second.content == "response-2")
    #expect(await session.prompts == ["Hello", "Be concise\n\nContinue"])
    #expect(await session.prewarmPrefixes == ["Story"])
}

@Test
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
func statefulAppleConversationSerializesOverlappingRequests() async throws {
    let session = MockAppleTextSession(delay: .milliseconds(10))
    let conversation = AppleFoundationModelConversation(
        session: session,
        sessionFactory: { session }
    )

    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<4 {
            group.addTask {
                _ = try await conversation.generate(
                    LanguageModelRequest(prompt: "Request \(index)")
                )
            }
        }
        try await group.waitForAll()
    }

    #expect(await session.peakConcurrentResponses == 1)
    #expect(await session.prompts.count == 4)
}

@Test
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
func resettingAStatefulAppleConversationUsesAFreshSession() async throws {
    let original = MockAppleTextSession(label: "original")
    let replacement = MockAppleTextSession(label: "replacement")
    let factory = MockAppleSessionFactory([replacement])
    let conversation = AppleFoundationModelConversation(
        session: original,
        sessionFactory: { factory.make() }
    )

    let first = try await conversation.generate(
        LanguageModelRequest(prompt: "Before reset")
    )
    try await conversation.reset()
    let second = try await conversation.generate(
        LanguageModelRequest(prompt: "After reset")
    )

    #expect(first.content == "original-1")
    #expect(second.content == "replacement-1")
    #expect(await original.prompts == ["Before reset"])
    #expect(await replacement.prompts == ["After reset"])
}

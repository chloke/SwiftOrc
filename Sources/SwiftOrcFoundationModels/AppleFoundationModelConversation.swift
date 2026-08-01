import Foundation
import FoundationModels
import SwiftOrc

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
protocol AppleFoundationModelTextSession: Sendable {
    func respond(
        to prompt: String,
        options: GenerationOptions
    ) async throws -> String

    func prewarm(promptPrefix: String?) async
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
struct SystemAppleFoundationModelTextSession: AppleFoundationModelTextSession {
    let session: LanguageModelSession

    func respond(
        to prompt: String,
        options: GenerationOptions
    ) async throws -> String {
        try await session.respond(to: prompt, options: options).content
    }

    func prewarm(promptPrefix: String?) async {
        session.prewarm(promptPrefix: promptPrefix.map(Prompt.init))
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private actor AppleFoundationModelConversationGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var isLocked = false
    private var waiters: [Waiter] = []

    func acquire() async throws {
        try Task.checkCancellation()
        guard isLocked else {
            isLocked = true
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().continuation.resume()
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(
            throwing: CancellationError()
        )
    }
}

/// A stateful Apple Foundation Models adapter for one app-managed conversation.
///
/// Keep one actor per conversation. Calls are serialized and Apple retains the
/// transcript between calls. `LanguageModelRequest.messages` is intentionally
/// rejected because the session itself is the source of conversation history.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
public actor AppleFoundationModelConversation: WorkflowLanguageModel {
    public static let providerIdentifier = AppleFoundationModel.providerIdentifier

    private let gate = AppleFoundationModelConversationGate()
    private let sessionFactory: @Sendable () -> any AppleFoundationModelTextSession
    private let availability: @Sendable () -> AppleFoundationModelAvailability
    private var session: any AppleFoundationModelTextSession

    public init(
        model: SystemLanguageModel = .default,
        instructions: String? = nil
    ) {
        let factory: @Sendable () -> any AppleFoundationModelTextSession = {
            SystemAppleFoundationModelTextSession(
                session: LanguageModelSession(
                    model: model,
                    instructions: instructions
                )
            )
        }
        let availabilitySource = AppleFoundationModel(model: model)
        sessionFactory = factory
        availability = { availabilitySource.availability }
        session = factory()
    }

    init(
        session: any AppleFoundationModelTextSession,
        sessionFactory: @escaping @Sendable () -> any AppleFoundationModelTextSession,
        availability: @escaping @Sendable () -> AppleFoundationModelAvailability = {
            .available
        }
    ) {
        self.session = session
        self.sessionFactory = sessionFactory
        self.availability = availability
    }

    /// Starts model loading before the first request. This is a performance
    /// hint and does not generate content.
    public func prewarm(promptPrefix: String? = nil) async throws {
        try await gate.acquire()
        await session.prewarm(promptPrefix: promptPrefix)
        await gate.release()
    }

    /// Discards the current transcript and starts a fresh conversation.
    public func reset() async throws {
        try await gate.acquire()
        session = sessionFactory()
        await gate.release()
    }

    public func generate(
        _ request: LanguageModelRequest
    ) async throws -> LanguageModelResponse {
        guard request.messages.isEmpty else {
            throw AppleFoundationModelError.unsupportedInput(
                kind: "explicit-conversation-history"
            )
        }
        guard request.responseFormat == nil else {
            throw AppleFoundationModelError.unsupportedInput(
                kind: "stateful-structured-output"
            )
        }
        guard request.tools.isEmpty else {
            throw AppleFoundationModelError.unsupportedInput(
                kind: "stateful-tool-calling"
            )
        }
        if case let .unavailable(reason) = availability() {
            throw AppleFoundationModelError.unavailable(reason)
        }

        let requestPrompt = try AppleFoundationModel.prompt(from: request)
        let prompt = [request.instructions, requestPrompt]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        try await gate.acquire()
        do {
            try Task.checkCancellation()
            let content = try await session.respond(
                to: prompt,
                options: Self.options(from: request.options)
            )
            await gate.release()
            return LanguageModelResponse(
                content: content,
                provider: Self.providerIdentifier
            )
        } catch {
            await gate.release()
            throw error
        }
    }

    private static func options(
        from options: LanguageModelGenerationOptions
    ) -> GenerationOptions {
        GenerationOptions(
            sampling: sampling(from: options.sampling),
            temperature: options.temperature,
            maximumResponseTokens: options.maximumResponseTokens
        )
    }

    private static func sampling(
        from sampling: LanguageModelSampling?
    ) -> GenerationOptions.SamplingMode? {
        switch sampling {
        case nil:
            nil
        case .greedy:
            .greedy
        case let .randomTopK(k, seed):
            .random(top: k, seed: seed)
        case let .randomProbabilityThreshold(threshold, seed):
            .random(probabilityThreshold: threshold, seed: seed)
        }
    }
}

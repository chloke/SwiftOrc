import Foundation
import SwiftOrc

/// One deterministic result returned by a ``ScriptedLanguageModel``.
///
/// Steps can optionally pause before completing so tests can exercise timeout
/// and cancellation behavior without contacting a model provider.
public struct ScriptedLanguageModelStep: Sendable {
    private enum Outcome: Sendable {
        case response(LanguageModelResponse)
        case failure(WorkflowFailure)
    }

    private let outcome: Outcome
    let delay: Duration

    private init(outcome: Outcome, delay: Duration) {
        self.outcome = outcome
        self.delay = delay
    }

    /// Creates a step that returns a complete provider-neutral response.
    public static func respond(
        with response: LanguageModelResponse,
        after delay: Duration = .zero
    ) -> ScriptedLanguageModelStep {
        ScriptedLanguageModelStep(
            outcome: .response(response),
            delay: delay
        )
    }

    /// Creates a text response using a recognizable testing provider.
    public static func respond(
        content: String,
        provider: String? = ScriptedLanguageModel.providerIdentifier,
        metadata: [String: String] = [:],
        after delay: Duration = .zero
    ) -> ScriptedLanguageModelStep {
        respond(
            with: LanguageModelResponse(
                content: content,
                provider: provider,
                metadata: metadata
            ),
            after: delay
        )
    }

    /// Creates a step that throws a structured failure.
    public static func fail(
        with failure: WorkflowFailure,
        after delay: Duration = .zero
    ) -> ScriptedLanguageModelStep {
        ScriptedLanguageModelStep(
            outcome: .failure(failure),
            delay: delay
        )
    }

    /// Creates an execution failure without exposing a concrete error type.
    public static func fail(
        message: String,
        kind: WorkflowFailure.Kind = .execution,
        errorType: String = "ScriptedLanguageModelFailure",
        after delay: Duration = .zero
    ) -> ScriptedLanguageModelStep {
        fail(
            with: WorkflowFailure(
                kind: kind,
                message: message,
                errorType: errorType
            ),
            after: delay
        )
    }

    fileprivate func resolve() throws -> LanguageModelResponse {
        switch outcome {
        case let .response(response):
            return response
        case let .failure(failure):
            throw failure
        }
    }
}

/// A privacy-conscious summary of a scripted model's current test state.
///
/// Requests are available because tests commonly need to inspect prompts and
/// policies. The model never logs them or includes them in exhaustion errors.
public struct ScriptedLanguageModelSnapshot: Sendable {
    public let requests: [LanguageModelRequest]
    public let consumedStepCount: Int
    public let remainingStepCount: Int

    public var allStepsConsumed: Bool {
        remainingStepCount == 0
    }
}

/// Errors produced by ``ScriptedLanguageModel`` itself.
public enum ScriptedLanguageModelError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    /// A request arrived after every configured step had been consumed.
    case scriptExhausted(requestNumber: Int)

    public var description: String {
        switch self {
        case let .scriptExhausted(requestNumber):
            return "The scripted model has no step for request \(requestNumber)."
        }
    }
}

/// A deterministic, recording language model for application and package tests.
///
/// Each call consumes one step in declaration order. The actor records requests
/// but never prints them or embeds them in errors, so sensitive fixture content
/// does not unexpectedly enter diagnostics.
public actor ScriptedLanguageModel: WorkflowLanguageModel {
    public static let providerIdentifier = "swiftorc-scripted"

    private let steps: [ScriptedLanguageModelStep]
    private var nextStepIndex = 0
    private var requests: [LanguageModelRequest] = []

    public init(steps: [ScriptedLanguageModelStep]) {
        self.steps = steps
    }

    public init(_ steps: ScriptedLanguageModelStep...) {
        self.init(steps: steps)
    }

    public func generate(
        _ request: LanguageModelRequest
    ) async throws -> LanguageModelResponse {
        try Task.checkCancellation()

        requests.append(request)
        let requestNumber = requests.count
        guard steps.indices.contains(nextStepIndex) else {
            throw ScriptedLanguageModelError.scriptExhausted(
                requestNumber: requestNumber
            )
        }

        let step = steps[nextStepIndex]
        nextStepIndex += 1

        if step.delay != .zero {
            try await Task.sleep(for: step.delay)
        }
        try Task.checkCancellation()
        return try step.resolve()
    }

    /// Returns the requests observed so far in call order.
    public func recordedRequests() -> [LanguageModelRequest] {
        requests
    }

    /// Returns request and consumption state in one consistent snapshot.
    public func snapshot() -> ScriptedLanguageModelSnapshot {
        ScriptedLanguageModelSnapshot(
            requests: requests,
            consumedStepCount: nextStepIndex,
            remainingStepCount: steps.count - nextStepIndex
        )
    }

    /// Restores the original script and clears recorded requests.
    public func reset() {
        nextStepIndex = 0
        requests.removeAll(keepingCapacity: true)
    }
}

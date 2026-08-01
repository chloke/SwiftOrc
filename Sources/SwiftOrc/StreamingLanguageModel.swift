/// One event emitted while a language model is generating a response.
public enum LanguageModelStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case completed(LanguageModelResponse)
}

/// A language model that can expose incremental text without changing the
/// ordinary one-response model interface.
public protocol StreamingWorkflowLanguageModel: WorkflowLanguageModel {
    func stream(
        _ request: LanguageModelRequest
    ) -> AsyncThrowingStream<LanguageModelStreamEvent, any Error>
}

public extension StreamingWorkflowLanguageModel {
    func generate(
        _ request: LanguageModelRequest
    ) async throws -> LanguageModelResponse {
        var accumulated = ""
        var completedResponse: LanguageModelResponse?

        for try await event in stream(request) {
            switch event {
            case let .textDelta(delta):
                accumulated += delta
            case let .completed(response):
                completedResponse = response
            }
        }

        guard var response = completedResponse else {
            throw LanguageModelStreamingError.missingCompletion
        }
        if response.content.isEmpty {
            response.content = accumulated
        }
        return response
    }
}

public enum LanguageModelStreamingError: Error, Sendable, Equatable {
    case missingCompletion
    case nonMonotonicSnapshot
}

/// A workflow node that publishes text deltas and reduces the final response.
public struct StreamingLanguageModelNode<State: Sendable>: WorkflowNode {
    public let id: NodeID

    private let model: any StreamingWorkflowLanguageModel
    private let makeRequest:
        @Sendable (
            State,
            WorkflowContext
        ) async throws -> LanguageModelRequest
    private let onDelta:
        @Sendable (
            String,
            WorkflowContext
        ) async -> Void
    private let reduce:
        @Sendable (
            LanguageModelResponse,
            State,
            WorkflowContext
        ) async throws -> NodeResult<State>

    public init<Model: StreamingWorkflowLanguageModel>(
        id: NodeID,
        model: Model,
        request:
            @escaping @Sendable (
                State,
                WorkflowContext
            ) async throws -> LanguageModelRequest,
        onDelta:
            @escaping @Sendable (
                String,
                WorkflowContext
            ) async -> Void = { _, _ in },
        reduce:
            @escaping @Sendable (
                LanguageModelResponse,
                State,
                WorkflowContext
            ) async throws -> NodeResult<State>
    ) {
        self.id = id
        self.model = model
        makeRequest = request
        self.onDelta = onDelta
        self.reduce = reduce
    }

    public func run(
        state: State,
        context: WorkflowContext
    ) async throws -> NodeResult<State> {
        let request = try await makeRequest(state, context)
        var completedResponse: LanguageModelResponse?

        for try await event in model.stream(request) {
            switch event {
            case let .textDelta(delta):
                await onDelta(delta, context)
            case let .completed(response):
                completedResponse = response
            }
        }

        guard let response = completedResponse else {
            throw LanguageModelStreamingError.missingCompletion
        }
        var result = try await reduce(response, state, context)
        if let routingReport = response.routingReport {
            result = .annotated(result, .languageModelRouting(routingReport))
        }
        if let toolReport = response.toolExecutionReport {
            result = .annotated(result, .languageModelTools(toolReport))
        }
        return result
    }
}

/// A closure-backed streaming model for adapters, previews, and tests.
public struct ClosureStreamingLanguageModel: StreamingWorkflowLanguageModel {
    private let operation:
        @Sendable (
            LanguageModelRequest
        ) -> AsyncThrowingStream<LanguageModelStreamEvent, any Error>

    public init(
        stream:
            @escaping @Sendable (
                LanguageModelRequest
            ) -> AsyncThrowingStream<LanguageModelStreamEvent, any Error>
    ) {
        operation = stream
    }

    public func stream(
        _ request: LanguageModelRequest
    ) -> AsyncThrowingStream<LanguageModelStreamEvent, any Error> {
        operation(request)
    }
}

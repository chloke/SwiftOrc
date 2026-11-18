/// A workflow node that requests schema-guided output, decodes it into a
/// concrete type, and reduces that value back into workflow state.
public struct StructuredLanguageModelNode<State, Output>: WorkflowNode
where State: Sendable, Output: LanguageModelStructuredOutput {
    public let id: NodeID

    private let model: StructuredLanguageModel<Output>
    private let makeRequest:
        @Sendable (
            State,
            WorkflowContext
        ) async throws -> LanguageModelRequest
    private let reduce:
        @Sendable (
            Output,
            LanguageModelResponse,
            State,
            WorkflowContext
        ) async throws -> NodeResult<State>
    private let conversation: LanguageModelNodeConversation<State>?

    public init<Model: WorkflowLanguageModel>(
        id: NodeID,
        model: Model,
        request:
            @escaping @Sendable (
                State,
                WorkflowContext
            ) async throws -> LanguageModelRequest,
        reduce:
            @escaping @Sendable (
                Output,
                LanguageModelResponse,
                State,
                WorkflowContext
            ) async throws -> NodeResult<State>
    ) {
        self.id = id
        self.model = StructuredLanguageModel(model: model)
        makeRequest = request
        self.reduce = reduce
        conversation = nil
    }

    /// Creates a node that keeps conversation history in workflow state, like
    /// ``LanguageModelNode/init(id:model:conversation:policy:request:reduce:)``.
    /// The recorded reply is the model's JSON output.
    public init<Model: WorkflowLanguageModel>(
        id: NodeID,
        model: Model,
        conversation: WritableKeyPath<State, LanguageModelConversation> & Sendable,
        policy: LanguageModelConversationPolicy = .default,
        request:
            @escaping @Sendable (
                State,
                WorkflowContext
            ) async throws -> LanguageModelRequest,
        reduce:
            @escaping @Sendable (
                Output,
                LanguageModelResponse,
                State,
                WorkflowContext
            ) async throws -> NodeResult<State>
    ) {
        self.id = id
        self.model = StructuredLanguageModel(model: model)
        makeRequest = request
        self.reduce = reduce
        self.conversation = LanguageModelNodeConversation(
            keyPath: conversation,
            policy: policy
        )
    }

    public func run(
        state: State,
        context: WorkflowContext
    ) async throws -> NodeResult<State> {
        let request = try await makeRequest(state, context)
        var state = state
        let structured: StructuredLanguageModelResponse<Output>
        if let conversation {
            switch try await conversation.generate(
                StructuredLanguageModel<Output>.structuredRequest(request),
                model: model.model,
                state: state,
                context: context,
                node: id
            ) {
            case let .completed(response, updated):
                // An undecodable reply is not saved to history.
                structured = try StructuredLanguageModel<Output>.decode(response)
                state = updated
            case let .suspended(result):
                return result
            }
        } else {
            structured = try await model.generate(request)
        }
        var result = try await reduce(
            structured.output,
            structured.response,
            state,
            context
        )

        if let routingReport = structured.response.routingReport {
            result = .annotated(
                result,
                .languageModelRouting(routingReport)
            )
        }
        if let toolReport = structured.response.toolExecutionReport {
            result = .annotated(
                result,
                .languageModelTools(toolReport)
            )
        }
        return result
    }
}

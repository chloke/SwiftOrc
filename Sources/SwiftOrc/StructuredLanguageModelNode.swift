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
    }

    public func run(
        state: State,
        context: WorkflowContext
    ) async throws -> NodeResult<State> {
        let request = try await makeRequest(state, context)
        let structured = try await model.generate(request)
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

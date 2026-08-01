/// A workflow node that builds a model request and reduces its response back
/// into workflow state.
public struct LanguageModelNode<State: Sendable>: WorkflowNode {
    public let id: NodeID

    private let model: any WorkflowLanguageModel
    private let makeRequest:
        @Sendable (
            State,
            WorkflowContext
        ) async throws -> LanguageModelRequest
    private let reduce:
        @Sendable (
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
                LanguageModelResponse,
                State,
                WorkflowContext
            ) async throws -> NodeResult<State>
    ) {
        self.id = id
        self.model = model
        makeRequest = request
        self.reduce = reduce
    }

    public func run(
        state: State,
        context: WorkflowContext
    ) async throws -> NodeResult<State> {
        let request = try await makeRequest(state, context)
        let response = try await model.generate(request)
        let result = try await reduce(response, state, context)

        var annotated = result
        if let routingReport = response.routingReport {
            annotated = .annotated(
                annotated,
                .languageModelRouting(routingReport)
            )
        }
        if let toolReport = response.toolExecutionReport {
            annotated = .annotated(
                annotated,
                .languageModelTools(toolReport)
            )
        }
        return annotated
    }
}

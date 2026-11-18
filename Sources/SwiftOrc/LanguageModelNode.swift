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
                LanguageModelResponse,
                State,
                WorkflowContext
            ) async throws -> NodeResult<State>
    ) {
        self.id = id
        self.model = model
        makeRequest = request
        self.reduce = reduce
        conversation = nil
    }

    /// Creates a node that keeps conversation history in workflow state.
    ///
    /// Before each request the node sends the stored history ahead of the
    /// prompt, keeps it within the context window using `policy`, and records
    /// the completed turn. `reduce` receives state with the turn already
    /// recorded. Because the conversation lives in state, it is saved with
    /// every checkpoint.
    ///
    /// When the model is a ``ToolCallingLanguageModel`` with
    /// ``LanguageModelToolApprovalMode/durable`` approvals, the node suspends
    /// the workflow with a ``WorkflowInputKind/toolApproval`` request and
    /// continues the turn after the application answers.
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
                LanguageModelResponse,
                State,
                WorkflowContext
            ) async throws -> NodeResult<State>
    ) {
        self.id = id
        self.model = model
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
        let response: LanguageModelResponse
        if let conversation {
            switch try await conversation.generate(
                request,
                model: model,
                state: state,
                context: context,
                node: id
            ) {
            case let .completed(completed, updated):
                response = completed
                state = updated
            case let .suspended(result):
                return result
            }
        } else {
            response = try await model.generate(request)
        }
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

struct LanguageModelNodeConversation<State: Sendable>: Sendable {
    let keyPath: WritableKeyPath<State, LanguageModelConversation> & Sendable
    let policy: LanguageModelConversationPolicy

    enum Outcome {
        case completed(LanguageModelResponse, State)
        /// The turn is paused: waiting for a tool approval, or checkpointed
        /// after a tool round before running the node again.
        case suspended(NodeResult<State>)
    }

    func generate(
        _ request: LanguageModelRequest,
        model: any WorkflowLanguageModel,
        state: State,
        context: WorkflowContext,
        node: NodeID
    ) async throws -> Outcome {
        var state = state
        var history = state[keyPath: keyPath]
        if var pending = history.pendingTurn,
            let inputRequest = pending.inputRequest
        {
            guard context.inputResponse?.request.id == inputRequest.id else {
                return .suspended(.awaitInput(state, request: inputRequest))
            }
            pending.applyAnswer(context.inputResponse?.value)
            pending.approvalRequestID = nil
            history.pendingTurn = pending
        }
        do {
            let response = try await LanguageModelConversationTurnRunner.generate(
                request,
                model: model,
                conversation: &history,
                policy: policy,
                artifactStore: context.artifactStore
            )
            state[keyPath: keyPath] = history
            return .completed(response, state)
        } catch let suspended as LanguageModelToolTurnSuspended {
            history.pendingTurn = suspended.pendingTurn
            state[keyPath: keyPath] = history
            if let inputRequest = suspended.pendingTurn.inputRequest {
                return .suspended(.awaitInput(state, request: inputRequest))
            }
            // Save a checkpoint after the tool round, then continue the turn.
            return .suspended(.next(state, node))
        }
    }
}

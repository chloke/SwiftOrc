import Foundation

/// Adds conversation history to any model, for use outside workflows.
///
/// Each `generate` call sends the stored history before the request's prompt,
/// keeps it within the context window using `policy`, and records the turn.
/// Calls are handled one at a time, so overlapping requests cannot interleave
/// their turns. Inside a workflow, prefer a ``LanguageModelNode`` with a
/// `conversation` key path, which saves history in checkpoints.
public actor ConversationalLanguageModel: WorkflowLanguageModel {
    public private(set) var conversation: LanguageModelConversation
    public var policy: LanguageModelConversationPolicy

    private let model: any WorkflowLanguageModel
    private let artifactStore: (any WorkflowArtifactStore)?
    private var isGenerating = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init<Model: WorkflowLanguageModel>(
        model: Model,
        conversation: LanguageModelConversation = LanguageModelConversation(),
        policy: LanguageModelConversationPolicy = .default,
        artifactStore: (any WorkflowArtifactStore)? = nil
    ) {
        self.model = model
        self.conversation = conversation
        self.policy = policy
        self.artifactStore = artifactStore
    }

    public func generate(
        _ request: LanguageModelRequest
    ) async throws -> LanguageModelResponse {
        await beginTurn()
        defer { endTurn() }
        try Task.checkCancellation()

        var updated = conversation
        let response = try await LanguageModelConversationTurnRunner.generate(
            request,
            model: model,
            conversation: &updated,
            policy: policy,
            artifactStore: artifactStore,
            // Durable tool approvals need a workflow to suspend; here a
            // durable model uses its approval handler instead.
            allowsSuspension: false
        )
        conversation = updated
        return response
    }

    /// Replaces the stored history, for example with one restored from disk.
    public func replaceConversation(_ conversation: LanguageModelConversation) {
        self.conversation = conversation
    }

    public func setPolicy(_ policy: LanguageModelConversationPolicy) {
        self.policy = policy
    }

    /// Discards all history.
    public func reset() {
        conversation.removeAll()
    }

    private func beginTurn() async {
        guard isGenerating else {
            isGenerating = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func endTurn() {
        if waiters.isEmpty {
            isGenerating = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

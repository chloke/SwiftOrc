import Foundation

/// Information about the current workflow execution supplied to every node.
public struct WorkflowContext: Sendable {
    public let executionID: UUID
    public let nodeID: NodeID

    /// The one-based attempt number for the current visit to this node.
    public let attempt: Int

    /// The one-based number of the node execution within the entire workflow run.
    public let step: Int

    /// Application-selected storage for binary inputs and outputs. The store
    /// itself is not included in workflow state or checkpoints.
    public let artifactStore: (any WorkflowArtifactStore)?

    init(
        executionID: UUID,
        nodeID: NodeID,
        attempt: Int,
        step: Int,
        artifactStore: (any WorkflowArtifactStore)?
    ) {
        self.executionID = executionID
        self.nodeID = nodeID
        self.attempt = attempt
        self.step = step
        self.artifactStore = artifactStore
    }

    /// Stores bytes without copying them into workflow state. When no source
    /// is supplied, the current node is recorded as their producer.
    public func storeArtifact(
        _ data: Data,
        options: WorkflowArtifactWriteOptions
    ) async throws -> WorkflowArtifact {
        guard let artifactStore else {
            throw WorkflowArtifactStoreError.notConfigured
        }
        var options = options
        if options.source == nil {
            options.source = .workflowNode(nodeID)
        }
        return try await artifactStore.store(data, options: options)
    }

    /// Resolves bytes only at the node or provider boundary that needs them.
    public func data(for artifact: WorkflowArtifact) async throws -> Data {
        guard let artifactStore else {
            throw WorkflowArtifactStoreError.notConfigured
        }
        return try await artifactStore.data(for: artifact)
    }

    /// Resolves a stored image into transient provider-neutral model input.
    public func imageInput(
        for artifact: WorkflowArtifact,
        detail: LanguageModelImageDetail = .automatic
    ) async throws -> LanguageModelInputPart {
        guard artifact.mediaType.lowercased().hasPrefix("image/") else {
            throw WorkflowArtifactStoreError.expectedImage(
                mediaType: artifact.mediaType
            )
        }
        return .image(
            LanguageModelImage(
                source: .data(
                    try await data(for: artifact),
                    mediaType: artifact.mediaType
                ),
                detail: detail
            )
        )
    }
}

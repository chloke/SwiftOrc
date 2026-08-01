import Foundation
import Testing

@testable import SwiftOrc

private struct ArtifactState: Sendable, Equatable, Codable {
    var artifact: WorkflowArtifact?
}

@Test
func workflowNodesStoreArtifactReferencesInsteadOfBytes() async throws {
    let store = try InMemoryWorkflowArtifactStore()
    let bytes = Data([0x89, 0x50, 0x4E, 0x47])
    let node = AnyWorkflowNode<ArtifactState>(id: "capture") { state, context in
        var state = state
        state.artifact = try await context.storeArtifact(
            bytes,
            options: WorkflowArtifactWriteOptions(
                mediaType: "image/png",
                suggestedFilename: "capture.png"
            )
        )
        return .finish(state)
    }
    let workflow = try Workflow(initialNode: "capture", nodes: [node])

    let run = try await workflow.run(
        ArtifactState(),
        artifactStore: store
    )

    let artifact = try #require(run.state.artifact)
    #expect(artifact.byteCount == bytes.count)
    #expect(artifact.source == .workflowNode("capture"))
    #expect(try await store.data(for: artifact) == bytes)
    let encodedState = try JSONEncoder().encode(run.state)
    #expect(encodedState.count < 1_024)
}

@Test
func workflowContextRequiresAnExplicitArtifactStore() async throws {
    let node = AnyWorkflowNode<ArtifactState>(id: "capture") { state, context in
        _ = try await context.storeArtifact(
            Data([1]),
            options: WorkflowArtifactWriteOptions(
                mediaType: "application/octet-stream"
            )
        )
        return .finish(state)
    }
    let workflow = try Workflow(initialNode: "capture", nodes: [node])

    do {
        _ = try await workflow.run(ArtifactState())
        Issue.record("Expected a missing artifact store to fail")
    } catch let execution as WorkflowExecutionError {
        #expect(
            execution.failure.errorType.contains("WorkflowArtifactStoreError")
        )
    }
}

@Test
func inMemoryArtifactStoreEnforcesCapacityLimits() async throws {
    let store = try InMemoryWorkflowArtifactStore(
        limits: WorkflowArtifactStoreLimits(
            maximumArtifactBytes: 3,
            maximumTotalBytes: 4
        )
    )
    _ = try await store.store(
        Data([1, 2, 3]),
        options: WorkflowArtifactWriteOptions(
            mediaType: "image/png",
            source: .userProvided
        )
    )

    do {
        _ = try await store.store(
            Data([4, 5]),
            options: WorkflowArtifactWriteOptions(mediaType: "image/png")
        )
        Issue.record("Expected total capacity to be enforced")
    } catch let error as WorkflowArtifactStoreError {
        #expect(error == .capacityExceeded(requested: 2, available: 1))
    }
}

@Test
func directoryArtifactStoreResolvesReferencesAfterReopening() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SwiftOrcArtifactTests-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let firstStore = try DirectoryWorkflowArtifactStore(
        directoryURL: directory
    )
    let bytes = Data("persistent-image".utf8)
    let artifact = try await firstStore.store(
        bytes,
        options: WorkflowArtifactWriteOptions(
            mediaType: "image/jpeg",
            source: .userProvided
        )
    )

    let reopenedStore = try DirectoryWorkflowArtifactStore(
        directoryURL: directory
    )
    #expect(try await reopenedStore.data(for: artifact) == bytes)

    try await reopenedStore.remove(artifact)
    do {
        _ = try await reopenedStore.data(for: artifact)
        Issue.record("Expected the removed artifact to be unavailable")
    } catch let error as WorkflowArtifactStoreError {
        #expect(error == .notFound(artifact.id))
    }
}

@Test
func contextResolvesStoredImagesIntoTransientModelInput() async throws {
    let store = try InMemoryWorkflowArtifactStore()
    let artifact = try await store.store(
        Data([1, 2, 3]),
        options: WorkflowArtifactWriteOptions(
            mediaType: "image/png",
            source: .userProvided
        )
    )
    let context = WorkflowContext(
        executionID: UUID(),
        nodeID: "vision",
        attempt: 1,
        step: 1,
        artifactStore: store
    )

    let input = try await context.imageInput(for: artifact, detail: .low)

    #expect(
        input
            == .image(
                LanguageModelImage(
                    source: .data(Data([1, 2, 3]), mediaType: "image/png"),
                    detail: .low
                )
            )
    )
}
